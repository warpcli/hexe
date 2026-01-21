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

pub fn handleInput(state: *State, input_bytes: []const u8) void {
    if (input_bytes.len == 0) return;

    const slice = consumeOscReplyFromTerminal(state, input_bytes);
    if (slice.len == 0) return;

    {
        const inp = slice;

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
            // Allow tab switching (Alt+N, Alt+P) - also support fallback keys for Alt+>/<'
            if (inp.len >= 2 and inp[0] == 0x1b and inp[1] != '[' and inp[1] != 'O') {
                const cfg = &state.config;
                const is_next = inp[1] == cfg.tabs.key_next or (cfg.tabs.key_next == '>' and inp[1] == '.');
                const is_prev = inp[1] == cfg.tabs.key_prev or (cfg.tabs.key_prev == '<' and inp[1] == ',');
                if (is_next or is_prev) {
                    // Allow tab switch.
                    if (handleAltKey(state, inp[1])) {
                        return;
                    }
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

            // Check for Alt+key (ESC followed by key).
            if (inp[i] == 0x1b and i + 1 < inp.len) {
                const next = inp[i + 1];
                // Check for CSI sequences (ESC [).
                if (next == '[' and i + 2 < inp.len) {
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
                    if (handleAltKey(state, next)) {
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
                    fpane.write(inp[i..]) catch {};
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
                        pane.write(inp[i..]) catch {};
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
                pane.write(inp[i..]) catch {};
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
        const dir: ?layout_mod.Layout.Direction = switch (inp[5]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => null,
        };

        if (dir) |d| {
            const old_uuid = state.getCurrentFocusedUuid();

            // Get cursor position from current pane for smarter direction targeting.
            var cursor_x: u16 = 0;
            var cursor_y: u16 = 0;
            var have_cursor = false;
            if (state.active_floating) |idx| {
                const pos = state.floats.items[idx].getCursorPos();
                cursor_x = pos.x;
                cursor_y = pos.y;
                have_cursor = true;
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                const pos = pane.getCursorPos();
                cursor_x = pos.x;
                cursor_y = pos.y;
                have_cursor = true;
            }

            const cursor: ?layout_mod.CursorPos = if (have_cursor) .{ .x = cursor_x, .y = cursor_y } else null;
            if (focusDirectionAny(state, d, cursor)) |target| {
                // Update focus to the selected target.
                if (target.kind == .float) {
                    state.active_floating = target.float_index;
                } else {
                    state.active_floating = null;
                }
                state.syncPaneFocus(target.pane, old_uuid);
                state.renderer.invalidate();
                state.force_full_render = true;
            }

            state.needs_render = true;
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

fn handleAltKey(state: *State, key: u8) bool {
    const cfg = &state.config;

    if (key == cfg.key_quit) {
        if (cfg.confirm_on_exit) {
            state.pending_action = .exit;
            state.popups.showConfirm("Exit mux?", .{}) catch {};
            state.needs_render = true;
        } else {
            state.running = false;
        }
        return true;
    }

    // Disown pane - orphans current pane in ses, spawns new shell in same place.
    if (key == cfg.key_disown) {
        // Get the current pane (float or tiled).
        const current_pane: ?*Pane = if (state.active_floating) |idx|
            state.floats.items[idx]
        else
            state.currentLayout().getFocusedPane();

        // Block disown for sticky floats only.
        if (current_pane) |p| {
            if (p.sticky) {
                state.notifications.show("Cannot disown sticky float");
                state.needs_render = true;
                return true;
            }
        }

        if (cfg.confirm_on_disown) {
            state.pending_action = .disown;
            state.popups.showConfirm("Disown pane?", .{}) catch {};
            state.needs_render = true;
        } else {
            actions.performDisown(state);
        }
        return true;
    }

    // Adopt orphaned pane - interactive flow with picker and confirm.
    if (key == cfg.key_adopt) {
        actions.startAdoptFlow(state);
        return true;
    }

    // Split keys.
    const split_h_key = cfg.splits.key_split_h;
    const split_v_key = cfg.splits.key_split_v;

    if (key == split_h_key) {
        const parent_uuid = state.getCurrentFocusedUuid();
        // Refresh CWD from ses for pod panes before splitting.
        const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
        if (state.currentLayout().splitFocused(.horizontal, cwd) catch null) |new_pane| {
            state.syncPaneAux(new_pane, parent_uuid);
        }
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    if (key == split_v_key) {
        const parent_uuid = state.getCurrentFocusedUuid();
        // Refresh CWD from ses for pod panes before splitting.
        const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
        if (state.currentLayout().splitFocused(.vertical, cwd) catch null) |new_pane| {
            state.syncPaneAux(new_pane, parent_uuid);
        }
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    // Alt+t = new tab.
    if (key == cfg.tabs.key_new) {
        state.active_floating = null;
        state.createTab() catch {};
        state.needs_render = true;
        return true;
    }

    // Alt+n = next tab (also support Alt+. as fallback for Alt+>).
    if (key == cfg.tabs.key_next or (cfg.tabs.key_next == '>' and key == '.')) {
        const old_uuid = state.getCurrentFocusedUuid();
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                const fp = state.floats.items[idx];
                // Always clear float focus when switching tabs.
                state.syncPaneUnfocus(fp);
                state.active_floating = null;
            }
        } else if (state.currentLayout().getFocusedPane()) |old_pane| {
            state.syncPaneUnfocus(old_pane);
        }
        state.nextTab();

        // Restore last focused float for this tab if the tab's last focus was a float.
        if (state.tab_last_focus_kind.items.len > state.active_tab and state.tab_last_focus_kind.items[state.active_tab] == .float) {
            if (state.tab_last_floating_uuid.items.len > state.active_tab) {
                if (state.tab_last_floating_uuid.items[state.active_tab]) |uuid| {
                    for (state.floats.items, 0..) |pane, fi| {
                        if (!std.mem.eql(u8, &pane.uuid, &uuid)) continue;
                        if (!pane.isVisibleOnTab(state.active_tab)) continue;
                        if (pane.parent_tab) |parent| {
                            if (parent != state.active_tab) continue;
                        }
                        state.active_floating = fi;
                        state.syncPaneFocus(pane, old_uuid);
                        state.needs_render = true;
                        return true;
                    }
                }
            }
        }

        if (state.currentLayout().getFocusedPane()) |new_pane| {
            state.syncPaneFocus(new_pane, old_uuid);
        }
        state.needs_render = true;
        return true;
    }

    // Alt+p = previous tab (also support Alt+, as fallback for Alt+<).
    if (key == cfg.tabs.key_prev or (cfg.tabs.key_prev == '<' and key == ',')) {
        const old_uuid = state.getCurrentFocusedUuid();
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                const fp = state.floats.items[idx];
                // Always clear float focus when switching tabs.
                state.syncPaneUnfocus(fp);
                state.active_floating = null;
            }
        } else if (state.currentLayout().getFocusedPane()) |old_pane| {
            state.syncPaneUnfocus(old_pane);
        }
        state.prevTab();

        // Restore last focused float for this tab if the tab's last focus was a float.
        if (state.tab_last_focus_kind.items.len > state.active_tab and state.tab_last_focus_kind.items[state.active_tab] == .float) {
            if (state.tab_last_floating_uuid.items.len > state.active_tab) {
                if (state.tab_last_floating_uuid.items[state.active_tab]) |uuid| {
                    for (state.floats.items, 0..) |pane, fi| {
                        if (!std.mem.eql(u8, &pane.uuid, &uuid)) continue;
                        if (!pane.isVisibleOnTab(state.active_tab)) continue;
                        if (pane.parent_tab) |parent| {
                            if (parent != state.active_tab) continue;
                        }
                        state.active_floating = fi;
                        state.syncPaneFocus(pane, old_uuid);
                        state.needs_render = true;
                        return true;
                    }
                }
            }
        }

        if (state.currentLayout().getFocusedPane()) |new_pane| {
            state.syncPaneFocus(new_pane, old_uuid);
        }
        state.needs_render = true;
        return true;
    }

    // Alt+x (configurable) = close current float/tab (or quit if last tab).
    if (key == cfg.tabs.key_close) {
        if (cfg.confirm_on_close) {
            state.pending_action = .close;
            const msg = if (state.active_floating != null) "Close float?" else "Close tab?";
            state.popups.showConfirm(msg, .{}) catch {};
            state.needs_render = true;
        } else {
            actions.performClose(state);
        }
        return true;
    }

    // Alt+d = detach whole mux - keeps all panes alive in ses for --attach.
    if (key == cfg.tabs.key_detach) {
        if (cfg.confirm_on_detach) {
            state.pending_action = .detach;
            state.popups.showConfirm("Detach session?", .{}) catch {};
            state.needs_render = true;
            return true;
        }
        actions.performDetach(state);
        return true;
    }

    // Alt+space - toggle floating focus (always space).
    if (key == ' ') {
        if (state.floats.items.len > 0) {
            const old_uuid = state.getCurrentFocusedUuid();
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    state.syncPaneUnfocus(state.floats.items[idx]);
                }
                state.active_floating = null;
                if (state.currentLayout().getFocusedPane()) |new_pane| {
                    state.syncPaneFocus(new_pane, old_uuid);
                }
            } else {
                // Find first float valid for current tab.
                var first_valid: ?usize = null;
                for (state.floats.items, 0..) |fp, fi| {
                    // Skip tab-bound floats on wrong tab.
                    if (fp.parent_tab) |parent| {
                        if (parent != state.active_tab) continue;
                    }
                    first_valid = fi;
                    break;
                }

                if (first_valid) |valid_idx| {
                    if (state.currentLayout().getFocusedPane()) |old_pane| {
                        state.syncPaneUnfocus(old_pane);
                    }
                    state.active_floating = valid_idx;
                    state.syncPaneFocus(state.floats.items[valid_idx], old_uuid);
                }
            }
            state.needs_render = true;
        }
        return true;
    }

    // Check for named float keys from config.
    if (cfg.getFloatByKey(key)) |float_def| {
        actions.toggleNamedFloat(state, float_def);
        state.needs_render = true;
        return true;
    }

    return false;
}
