const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const SesClient = @import("ses_client.zig").SesClient;

const input = @import("input.zig");
const helpers = @import("helpers.zig");

const actions = @import("loop_actions.zig");
const loop_ipc = @import("loop_ipc.zig");
const TabFocusKind = @import("state.zig").TabFocusKind;
const statusbar = @import("statusbar.zig");
const keybinds = @import("keybinds.zig");
const input_csi_u = @import("input_csi_u.zig");

fn forwardSanitizedToFocusedPane(state: *State, bytes: []const u8) void {
    input_csi_u.forwardSanitizedToFocusedPane(state, bytes);
}

fn mergeStdinTail(state: *State, input_bytes: []const u8) struct { merged: []const u8, owned: ?[]u8 } {
    if (state.stdin_tail_len == 0) return .{ .merged = input_bytes, .owned = null };

    const tl: usize = @intCast(state.stdin_tail_len);
    const total = tl + input_bytes.len;
    var tmp = state.allocator.alloc(u8, total) catch {
        // Allocation failure: drop tail rather than corrupt memory.
        state.stdin_tail_len = 0;
        return .{ .merged = input_bytes, .owned = null };
    };
    @memcpy(tmp[0..tl], state.stdin_tail[0..tl]);
    @memcpy(tmp[tl..total], input_bytes);
    state.stdin_tail_len = 0;
    return .{ .merged = tmp, .owned = tmp };
}


fn stashIncompleteEscapeTail(state: *State, inp: []const u8) []const u8 {
    const ESC: u8 = 0x1b;
    const BEL: u8 = 0x07;

    // Find the last ESC in the buffer.
    var last_esc: ?usize = null;
    var i: usize = inp.len;
    while (i > 0) {
        i -= 1;
        if (inp[i] == ESC) {
            last_esc = i;
            break;
        }
    }
    if (last_esc == null) return inp;
    const esc_i = last_esc.?;

    // If ESC is the last byte, it's definitely incomplete.
    if (esc_i + 1 >= inp.len) {
        return stashFromIndex(state, inp, esc_i);
    }

    const next = inp[esc_i + 1];
    // CSI: ESC [ ... <final>
    if (next == '[') {
        var j: usize = esc_i + 2;
        while (j < inp.len) : (j += 1) {
            const b = inp[j];
            // CSI final byte is 0x40..0x7E
            if (b >= 0x40 and b <= 0x7e) return inp;
        }
        return stashFromIndex(state, inp, esc_i);
    }

    // SS3: ESC O <final>
    if (next == 'O') {
        if (esc_i + 2 >= inp.len) return stashFromIndex(state, inp, esc_i);
        return inp;
    }

    // OSC: ESC ] ... (BEL or ESC \\)
    if (next == ']') {
        var j: usize = esc_i + 2;
        while (j < inp.len) : (j += 1) {
            const b = inp[j];
            if (b == BEL) return inp;
            if (b == ESC and j + 1 < inp.len and inp[j + 1] == '\\') return inp;
        }
        return stashFromIndex(state, inp, esc_i);
    }

    // Alt/meta: ESC <byte>
    // If we have the byte, it's complete.
    return inp;
}

fn stashFromIndex(state: *State, inp: []const u8, start: usize) []const u8 {
    const tail = inp[start..];
    if (tail.len == 0) return inp;
    if (tail.len > state.stdin_tail.len) {
        // Too large to stash; don't block input.
        return inp;
    }
    @memcpy(state.stdin_tail[0..tail.len], tail);
    state.stdin_tail_len = @intCast(tail.len);
    return inp[0..start];
}

pub fn handleInput(state: *State, input_bytes: []const u8) void {
    if (input_bytes.len == 0) return;

    // Stdin reads can split escape sequences. Merge with any pending tail first.
    const merged_res = mergeStdinTail(state, input_bytes);
    defer if (merged_res.owned) |m| state.allocator.free(m);

    const slice = consumeOscReplyFromTerminal(state, merged_res.merged);
    if (slice.len == 0) return;

    // Don't process (or forward) partial escape sequences.
    const stable = stashIncompleteEscapeTail(state, slice);
    if (stable.len == 0) return;

    {
        const inp = stable;

        // ==========================================================================
        // LEVEL 1: MUX-level popup blocks EVERYTHING
        // ==========================================================================
        if (state.popups.isBlocked()) {
            if (input.handlePopupInput(&state.popups, inp)) {
                // Check if this was a confirm/picker dialog for pending action
                if (state.pending_action) |action| {
                    switch (action) {
                        .adopt_choose => {
                            // Handle picker result for selecting orphaned pane
                            if (state.popups.getPickerResult()) |selected| {
                                if (selected < state.adopt_orphan_count) {
                                    state.adopt_selected_uuid = state.adopt_orphans[selected].uuid;
                                    // Now show confirm dialog
                                    state.pending_action = .adopt_confirm;
                                    state.popups.clearResults();
                                    state.popups.showConfirm("Destroy current pane?", .{}) catch {};
                                } else {
                                    state.pending_action = null;
                                }
                            } else if (state.popups.wasPickerCancelled()) {
                                state.pending_action = null;
                                state.popups.clearResults();
                            }
                        },
                        .adopt_confirm => {
                            // Handle confirm result for adopt action
                            if (state.popups.getConfirmResult()) |destroy_current| {
                                if (state.adopt_selected_uuid) |uuid| {
                                    actions.performAdopt(state, uuid, destroy_current);
                                }
                            }
                            state.pending_action = null;
                            state.adopt_selected_uuid = null;
                            state.popups.clearResults();
                        },
                        else => {
                            // Handle other confirm dialogs (exit/detach/disown/close)
                            if (state.popups.getConfirmResult()) |confirmed| {
                                if (confirmed) {
                                    switch (action) {
                                        .exit => state.running = false,
                                        .exit_intent => {
                                            // Shell will exit itself; we only approve.
                                            // Arm a short window to skip the later "Shell exited" confirm.
                                            state.exit_intent_deadline_ms = std.time.milliTimestamp() + 5000;
                                        },
                                        .detach => actions.performDetach(state),
                                        .disown => actions.performDisown(state),
                                        .close => actions.performClose(state),
                                        else => {},
                                    }
                                } else {
                                    // User cancelled - if exit was from shell death, respawn
                                    if (action == .exit and state.exit_from_shell_death) {
                                        if (state.currentLayout().getFocusedPane()) |pane| {
                                            switch (pane.backend) {
                                                .local => {
                                                    pane.respawn() catch {
                                                        state.notifications.show("Respawn failed");
                                                    };
                                                    state.skip_dead_check = true;
                                                },
                                                .pod => {
                                                    const cwd = state.getSpawnCwd(pane);
                                                    const old_aux = state.ses_client.getPaneAux(pane.uuid) catch SesClient.PaneAuxInfo{
                                                        .created_from = null,
                                                        .focused_from = null,
                                                    };
                                                    state.ses_client.killPane(pane.uuid) catch {};
                                                    if (state.ses_client.createPane(null, cwd, null, null, null, null)) |result| {
                                                        defer state.allocator.free(result.socket_path);
                                                        var replaced = true;
                                                        pane.replaceWithPod(result.socket_path, result.uuid) catch {
                                                            replaced = false;
                                                        };
                                                        if (replaced) {
                                                            const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
                                                            const cursor = pane.getCursorPos();
                                                            const cursor_style = pane.vt.getCursorStyle();
                                                            const cursor_visible = pane.vt.isCursorVisible();
                                                            const alt_screen = pane.vt.inAltScreen();
                                                            const layout_path = helpers.getLayoutPath(state, pane) catch null;
                                                            defer if (layout_path) |path| state.allocator.free(path);
                                                            state.ses_client.updatePaneAux(
                                                                pane.uuid,
                                                                pane.floating,
                                                                pane.focused,
                                                                pane_type,
                                                                old_aux.created_from,
                                                                old_aux.focused_from,
                                                                .{ .x = cursor.x, .y = cursor.y },
                                                                cursor_style,
                                                                cursor_visible,
                                                                alt_screen,
                                                                .{ .cols = pane.width, .rows = pane.height },
                                                                pane.getPwd(),
                                                                null,
                                                                null,
                                                                layout_path,
                                                            ) catch {};
                                                            state.skip_dead_check = true;
                                                        } else {
                                                            state.notifications.show("Respawn failed");
                                                        }
                                                    } else |_| {
                                                        state.notifications.show("Respawn failed");
                                                    }
                                                },
                                            }
                                        }
                                    }
                                }

                                // Reply to a pending exit_intent IPC client, if any.
                                if (action == .exit_intent) {
                                    if (state.pending_exit_intent_fd) |fd| {
                                        var c = core.ipc.Connection{ .fd = fd };
                                        if (confirmed) {
                                            c.sendLine("{\"type\":\"exit_intent_result\",\"allow\":true}") catch {};
                                        } else {
                                            c.sendLine("{\"type\":\"exit_intent_result\",\"allow\":false}") catch {};
                                        }
                                        c.close();
                                    }
                                    state.pending_exit_intent_fd = null;
                                }
                            }
                            state.pending_action = null;
                            state.exit_from_shell_death = false;
                            state.popups.clearResults();
                        },
                    }
                } else {
                    loop_ipc.sendPopResponse(state);
                }
            }
            state.needs_render = true;
            return;
        }

        // ==========================================================================
        // LEVEL 2: TAB-level popup - allows tab switching, blocks rest
        // ==========================================================================
        const current_tab = &state.tabs.items[state.active_tab];
        if (current_tab.popups.isBlocked()) {
            // Allow only tab switching while a tab popup is open.
            if (inp.len >= 2 and inp[0] == 0x1b and inp[1] != '[' and inp[1] != 'O') {
                if (keybinds.handleKeyEvent(state, 1, .{ .char = inp[1] }, .press, true, false)) {
                    return;
                }
            }
            // Block everything else - handle popup input.
            if (input.handlePopupInput(&current_tab.popups, inp)) {
                loop_ipc.sendPopResponse(state);
            }
            state.needs_render = true;
            return;
        }

        var i: usize = 0;
        while (i < inp.len) {
            // If some external layer injects CSI-u key events, translate them to
            // mux binds / legacy bytes so Alt bindings keep working and no garbage
            // is forwarded into the shell.
            if (input_csi_u.parse(inp[i..])) |ev| {
                if (ev.event_type != 3) {
                    if (keybinds.handleKeyEvent(state, ev.mods, ev.key, .press, false, false)) {
                        i += ev.consumed;
                        continue;
                    }
                    var out: [8]u8 = undefined;
                    if (input_csi_u.translateToLegacy(&out, ev)) |out_len| {
                        keybinds.forwardInputToFocusedPane(state, out[0..out_len]);
                    }
                }
                i += ev.consumed;
                continue;
            }
            // Mouse events (SGR): click-to-focus and status-bar tab switching.
            if (input.parseMouseEvent(inp[i..])) |ev| {
                const raw = inp[i .. i + ev.consumed];

                // Status bar tab switching (only on press).
                if (!ev.is_release and state.config.tabs.status.enabled and ev.y == state.term_height - 1) {
                    if (statusbar.hitTestTab(state.allocator, &state.config, state.term_width, state.term_height, state.tabs, state.active_tab, state.session_name, ev.x, ev.y)) |ti| {
                        if (ti != state.active_tab) {
                            switchToTab(state, ti);
                        }
                        // Do not forward clicks to apps when clicking the status bar.
                        i += ev.consumed;
                        continue;
                    }
                }

                // Determine target under the cursor (prefer floats).
                const target = findFocusableAt(state, ev.x, ev.y);
                const forward_to_app = if (target) |t| t.pane.vt.inAltScreen() else false;

                // Wheel scroll (64/65):
                // - In alt screen: forward to the app (btop, cmatrix, etc)
                // - Otherwise: use mux scrollback
                if (!ev.is_release and (ev.btn == 64 or ev.btn == 65)) {
                    if (target) |t| {
                        if (forward_to_app) {
                            // Forward to app.
                            t.pane.write(raw) catch {};
                        } else {
                            if (ev.btn == 64) {
                                t.pane.scrollUp(3);
                            } else {
                                t.pane.scrollDown(3);
                            }
                            state.needs_render = true;
                        }
                    } else {
                        // No target: forward to current focus if any.
                        if (state.active_floating) |afi| {
                            if (afi < state.floats.items.len) {
                                state.floats.items[afi].write(raw) catch {};
                            }
                        } else if (state.currentLayout().getFocusedPane()) |p| {
                            p.write(raw) catch {};
                        }
                    }
                    i += ev.consumed;
                    continue;
                }

                // Left button press always focuses.
                // Only forward the click to the app if the target is in alt-screen.
                if (!ev.is_release and (ev.btn & 3) == 0) {
                    if (target) |t| {
                        focusTarget(state, t);
                        if (forward_to_app) {
                            t.pane.write(raw) catch {};
                        }
                    } else {
                        // Nothing hit; forward to current focus.
                        if (state.active_floating) |afi| {
                            if (afi < state.floats.items.len) {
                                if (state.floats.items[afi].vt.inAltScreen()) {
                                    state.floats.items[afi].write(raw) catch {};
                                }
                            }
                        } else if (state.currentLayout().getFocusedPane()) |p| {
                            if (p.vt.inAltScreen()) {
                                p.write(raw) catch {};
                            }
                        }
                    }
                    i += ev.consumed;
                    continue;
                }

                // Other mouse events (including release):
                // Only forward when the target is in alt-screen.
                if (target) |t| {
                    if (forward_to_app) {
                        t.pane.write(raw) catch {};
                    }
                } else if (state.active_floating) |afi| {
                    if (afi < state.floats.items.len) {
                        if (state.floats.items[afi].vt.inAltScreen()) {
                            state.floats.items[afi].write(raw) catch {};
                        }
                    }
                } else if (state.currentLayout().getFocusedPane()) |p| {
                    if (p.vt.inAltScreen()) {
                        p.write(raw) catch {};
                    }
                }

                i += ev.consumed;
                continue;
            }

            // No kitty keyboard protocol support.
            if (inp[i] == 0x1b and i + 1 < inp.len) {
                const next = inp[i + 1];
                // Check for CSI sequences (ESC [).
                if (next == '[' and i + 2 < inp.len) {
                    // If this looks like a kitty CSI-u key event and parsing didn't
                    // handle it above, swallow it so it never leaks into the shell.
                    // This is intentionally conservative: we only swallow sequences
                    // that start like a CSI numeric parameter and end in 'u'.
                    if (inp[i + 2] >= '0' and inp[i + 2] <= '9') {
                        var j: usize = i + 2;
                        const end = @min(inp.len, i + 64);
                        while (j < end and inp[j] != 'u') : (j += 1) {}
                        if (j < end and inp[j] == 'u') {
                            i = j + 1;
                            continue;
                        }
                    }
                    // Handle Alt+Arrow for directional navigation: ESC [ 1 ; 3 <dir>
                    if (handleAltArrow(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                    // Handle scroll keys.
                    if (handleScrollKeys(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                }
                // Make sure it's not an actual escape sequence (like arrow keys).
                if (next != '[' and next != 'O') {
                    if (keybinds.handleKeyEvent(state, 1, .{ .char = next }, .press, false, false)) {
                        i += 2;
                        continue;
                    }
                }
            }

            // Check for Ctrl+Q to quit.
            if (inp[i] == 0x11) {
                state.running = false;
                return;
            }

            // ==========================================================================
            // LEVEL 3: PANE-level popup - blocks only input to that specific pane
            // ==========================================================================
            if (state.active_floating) |idx| {
                const fpane = state.floats.items[idx];
                // Check tab ownership for tab-bound floats.
                const can_interact = if (fpane.parent_tab) |parent|
                    parent == state.active_tab
                else
                    true;

                if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
                    // Check if this float pane has a blocking popup.
                    if (fpane.popups.isBlocked()) {
                        if (input.handlePopupInput(&fpane.popups, inp[i..])) {
                            loop_ipc.sendPopResponse(state);
                        }
                        state.needs_render = true;
                        return;
                    }
                    if (fpane.isScrolled()) {
                        fpane.scrollToBottom();
                        state.needs_render = true;
                    }
                    forwardSanitizedToFocusedPane(state, inp[i..]);
                } else {
                    // Can't input to tab-bound float on wrong tab, forward to tiled pane.
                    if (state.currentLayout().getFocusedPane()) |pane| {
                        // Check if this pane has a blocking popup.
                        if (pane.popups.isBlocked()) {
                            if (input.handlePopupInput(&pane.popups, inp[i..])) {
                                loop_ipc.sendPopResponse(state);
                            }
                            state.needs_render = true;
                            return;
                        }
                        if (pane.isScrolled()) {
                            pane.scrollToBottom();
                            state.needs_render = true;
                        }
                        forwardSanitizedToFocusedPane(state, inp[i..]);
                    }
                }
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                // Check if this pane has a blocking popup.
                if (pane.popups.isBlocked()) {
                    if (input.handlePopupInput(&pane.popups, inp[i..])) {
                        loop_ipc.sendPopResponse(state);
                    }
                    state.needs_render = true;
                    return;
                }
                if (pane.isScrolled()) {
                    pane.scrollToBottom();
                    state.needs_render = true;
                }
                forwardSanitizedToFocusedPane(state, inp[i..]);
            }
            return;
        }
    }
}

const FocusTargetKind = enum { split, float };

const FocusTarget = struct {
    kind: FocusTargetKind,
    pane: *Pane,
    float_index: ?usize,
};

fn isFloatRenderableOnTab(pane: *Pane, tab_idx: usize) bool {
    if (!pane.isVisibleOnTab(tab_idx)) return false;
    if (pane.parent_tab) |parent| {
        return parent == tab_idx;
    }
    return true;
}

fn findFocusableAt(state: *State, x: u16, y: u16) ?FocusTarget {
    // Floats are topmost - check active first, then others in reverse.
    if (state.active_floating) |afi| {
        if (afi < state.floats.items.len) {
            const fp = state.floats.items[afi];
            if (isFloatRenderableOnTab(fp, state.active_tab)) {
                if (x >= fp.border_x and x < fp.border_x + fp.border_w and y >= fp.border_y and y < fp.border_y + fp.border_h) {
                    return .{ .kind = .float, .pane = fp, .float_index = afi };
                }
            }
        }
    }

    var fi: usize = state.floats.items.len;
    while (fi > 0) {
        fi -= 1;
        const fp = state.floats.items[fi];
        if (!isFloatRenderableOnTab(fp, state.active_tab)) continue;
        if (x >= fp.border_x and x < fp.border_x + fp.border_w and y >= fp.border_y and y < fp.border_y + fp.border_h) {
            return .{ .kind = .float, .pane = fp, .float_index = fi };
        }
    }

    var it = state.currentLayout().splits.valueIterator();
    while (it.next()) |pane_ptr| {
        const p = pane_ptr.*;
        if (x >= p.x and x < p.x + p.width and y >= p.y and y < p.y + p.height) {
            return .{ .kind = .split, .pane = p, .float_index = null };
        }
    }
    return null;
}

fn focusTarget(state: *State, target: FocusTarget) void {
    const old_uuid = state.getCurrentFocusedUuid();
    if (target.kind == .float) {
        state.active_floating = target.float_index;
        state.syncPaneFocus(target.pane, old_uuid);
    } else {
        state.active_floating = null;
        state.syncPaneFocus(target.pane, old_uuid);
    }
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

fn focusDirectionAny(state: *State, dir: layout_mod.Layout.Direction, cursor_pos: ?layout_mod.CursorPos) ?FocusTarget {
    const current: *Pane = if (state.active_floating) |idx| blk: {
        if (idx < state.floats.items.len) break :blk state.floats.items[idx];
        break :blk state.currentLayout().getFocusedPane() orelse return null;
    } else state.currentLayout().getFocusedPane() orelse return null;

    const cur_cx = if (cursor_pos) |pos| pos.x else current.x + current.width / 2;
    const cur_cy = if (cursor_pos) |pos| pos.y else current.y + current.height / 2;

    var best: ?FocusTarget = null;
    var best_dist: i32 = std.math.maxInt(i32);

    // Consider floats first (top-level focus targets).
    for (state.floats.items, 0..) |fp, fi| {
        if (!isFloatRenderableOnTab(fp, state.active_tab)) continue;
        if (fp == current) continue;

        const is_valid = switch (dir) {
            .up => fp.y + fp.height <= current.y,
            .down => fp.y >= current.y + current.height,
            .left => fp.x + fp.width <= current.x,
            .right => fp.x >= current.x + current.width,
        };
        if (!is_valid) continue;

        const pane_cx = fp.x + fp.width / 2;
        const pane_cy = fp.y + fp.height / 2;
        const dist: i32 = switch (dir) {
            .up, .down => blk: {
                const dy = @as(i32, @intCast(cur_cy)) - @as(i32, @intCast(pane_cy));
                const dx = @as(i32, @intCast(cur_cx)) - @as(i32, @intCast(pane_cx));
                break :blk @as(i32, @intCast(@abs(dy))) + @divTrunc(@as(i32, @intCast(@abs(dx))), 2);
            },
            .left, .right => blk: {
                const dx = @as(i32, @intCast(cur_cx)) - @as(i32, @intCast(pane_cx));
                const dy = @as(i32, @intCast(cur_cy)) - @as(i32, @intCast(pane_cy));
                break :blk @as(i32, @intCast(@abs(dx))) + @divTrunc(@as(i32, @intCast(@abs(dy))), 2);
            },
        };

        if (dist < best_dist) {
            best_dist = dist;
            best = .{ .kind = .float, .pane = fp, .float_index = fi };
        }
    }

    // Consider split panes.
    var it = state.currentLayout().splits.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr.*;
        if (p == current) continue;

        const is_valid = switch (dir) {
            .up => p.y + p.height <= current.y,
            .down => p.y >= current.y + current.height,
            .left => p.x + p.width <= current.x,
            .right => p.x >= current.x + current.width,
        };
        if (!is_valid) continue;

        const pane_cx = p.x + p.width / 2;
        const pane_cy = p.y + p.height / 2;
        const dist: i32 = switch (dir) {
            .up, .down => blk: {
                const dy = @as(i32, @intCast(cur_cy)) - @as(i32, @intCast(pane_cy));
                const dx = @as(i32, @intCast(cur_cx)) - @as(i32, @intCast(pane_cx));
                break :blk @as(i32, @intCast(@abs(dy))) + @divTrunc(@as(i32, @intCast(@abs(dx))), 2);
            },
            .left, .right => blk: {
                const dx = @as(i32, @intCast(cur_cx)) - @as(i32, @intCast(pane_cx));
                const dy = @as(i32, @intCast(cur_cy)) - @as(i32, @intCast(pane_cy));
                break :blk @as(i32, @intCast(@abs(dx))) + @divTrunc(@as(i32, @intCast(@abs(dy))), 2);
            },
        };

        if (dist < best_dist) {
            best_dist = dist;
            best = .{ .kind = .split, .pane = p, .float_index = null };
        }
    }

    return best;
}

fn restoreTabFocus(state: *State, old_uuid: ?[32]u8) void {
    // Restore float only if last focus kind was float.
    if (state.tab_last_focus_kind.items.len > state.active_tab and state.tab_last_focus_kind.items[state.active_tab] == .float) {
        if (state.tab_last_floating_uuid.items.len > state.active_tab) {
            if (state.tab_last_floating_uuid.items[state.active_tab]) |uuid| {
                for (state.floats.items, 0..) |pane, fi| {
                    if (!std.mem.eql(u8, &pane.uuid, &uuid)) continue;
                    if (!isFloatRenderableOnTab(pane, state.active_tab)) continue;
                    state.active_floating = fi;
                    state.syncPaneFocus(pane, old_uuid);
                    return;
                }
            }
        }
    }

    state.active_floating = null;
    if (state.currentLayout().getFocusedPane()) |new_pane| {
        state.syncPaneFocus(new_pane, old_uuid);
    }
}

fn switchToTab(state: *State, new_tab: usize) void {
    if (new_tab >= state.tabs.items.len) return;
    const old_uuid = state.getCurrentFocusedUuid();

    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) {
            state.syncPaneUnfocus(state.floats.items[idx]);
        }
        state.active_floating = null;
    } else if (state.currentLayout().getFocusedPane()) |old_pane| {
        state.syncPaneUnfocus(old_pane);
    }

    state.active_tab = new_tab;
    state.renderer.invalidate();
    state.force_full_render = true;

    restoreTabFocus(state, old_uuid);
    state.needs_render = true;
}

fn consumeOscReplyFromTerminal(state: *State, inp: []const u8) []const u8 {
    // Only do work if we previously forwarded a query.
    if (state.osc_reply_target_uuid == null and !state.osc_reply_in_progress) return inp;

    const ESC: u8 = 0x1b;
    const BEL: u8 = 0x07;

    // Start capture only if the input begins with an OSC response.
    if (!state.osc_reply_in_progress) {
        if (inp.len < 2 or inp[0] != ESC or inp[1] != ']') return inp;
        state.osc_reply_in_progress = true;
        state.osc_reply_prev_esc = false;
        state.osc_reply_buf.clearRetainingCapacity();
    }

    var i: usize = 0;
    while (i < inp.len) : (i += 1) {
        const b = inp[i];
        state.osc_reply_buf.append(state.allocator, b) catch {
            // Drop on allocation error.
            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();
            return inp[i + 1 ..];
        };

        var done = false;
        if (b == BEL) {
            done = true;
        } else if (state.osc_reply_prev_esc and b == '\\') {
            done = true;
        }
        state.osc_reply_prev_esc = (b == ESC);

        if (state.osc_reply_buf.items.len > 64 * 1024) {
            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();
            return inp[i + 1 ..];
        }

        if (done) {
            if (state.osc_reply_target_uuid) |uuid| {
                if (state.findPaneByUuid(uuid)) |pane| {
                    pane.write(state.osc_reply_buf.items) catch {};
                }
            }

            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();

            return inp[i + 1 ..];
        }
    }

    // Consumed everything into the pending reply buffer.
    return &[_]u8{};
}

/// Handle Alt+Arrow for directional pane navigation.
/// Sequence: ESC [ 1 ; 3 <A/B/C/D> (Alt+Up/Down/Right/Left)
/// Returns number of bytes consumed, or null if not an Alt+Arrow sequence.
fn handleAltArrow(state: *State, inp: []const u8) ?usize {
    // Check for ESC [ 1 ; 3 <dir> pattern (6 bytes)
    if (inp.len >= 6 and inp[0] == 0x1b and inp[1] == '[' and
        inp[2] == '1' and inp[3] == ';' and inp[4] == '3')
    {
        const key: ?core.Config.BindKey = switch (inp[5]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => null,
        };

        if (key) |k| {
            _ = keybinds.handleKeyEvent(state, 1, k, .press, false, false);
            return 6;
        }
    }

    return null;
}

/// Handle scroll-related escape sequences.
/// Returns number of bytes consumed, or null if not a scroll sequence.
fn handleScrollKeys(state: *State, inp: []const u8) ?usize {
    // Must start with ESC [
    if (inp.len < 3 or inp[0] != 0x1b or inp[1] != '[') return null;

    // Choose active pane (float or tiled)
    const pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();
    if (pane == null) return null;
    const p = pane.?;

    // PageUp: ESC [ 5 ~
    if (inp.len >= 4 and inp[2] == '5' and inp[3] == '~') {
        p.scrollUp(5);
        state.needs_render = true;
        return 4;
    }

    // PageDown: ESC [ 6 ~
    if (inp.len >= 4 and inp[2] == '6' and inp[3] == '~') {
        p.scrollDown(5);
        state.needs_render = true;
        return 4;
    }

    // Home: ESC [ H or ESC [ 1 ~
    if (inp.len >= 3 and inp[2] == 'H') {
        p.scrollToTop();
        state.needs_render = true;
        return 3;
    }
    if (inp.len >= 4 and inp[2] == '1' and inp[3] == '~') {
        p.scrollToTop();
        state.needs_render = true;
        return 4;
    }

    // End: ESC [ F or ESC [ 4 ~
    if (inp.len >= 3 and inp[2] == 'F') {
        p.scrollToBottom();
        state.needs_render = true;
        return 3;
    }
    if (inp.len >= 4 and inp[2] == '4' and inp[3] == '~') {
        p.scrollToBottom();
        state.needs_render = true;
        return 4;
    }

    // Shift+Up: ESC [ 1 ; 2 A - scroll up one line
    if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';' and inp[4] == '2' and inp[5] == 'A') {
        p.scrollUp(1);
        state.needs_render = true;
        return 6;
    }

    // Shift+Down: ESC [ 1 ; 2 B - scroll down one line
    if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';' and inp[4] == '2' and inp[5] == 'B') {
        p.scrollDown(1);
        state.needs_render = true;
        return 6;
    }

    return null;
}
