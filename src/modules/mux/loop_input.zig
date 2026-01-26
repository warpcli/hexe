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
const loop_mouse = @import("loop_mouse.zig");

const tab_switch = @import("tab_switch.zig");

// Mouse helpers moved to loop_mouse.zig.

/// Format raw input bytes for keycast display.
/// Returns the number of bytes consumed and the formatted text.
fn formatKeycastInput(inp: []const u8, buf: *[32]u8) struct { consumed: usize, text: []const u8 } {
    if (inp.len == 0) return .{ .consumed = 0, .text = "" };

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    const b = inp[0];

    // ESC sequences
    if (b == 0x1b) {
        if (inp.len == 1) {
            writer.writeAll("Esc") catch {};
            return .{ .consumed = 1, .text = buf[0..stream.pos] };
        }

        const next = inp[1];

        // CSI sequence: ESC [
        if (next == '[' and inp.len >= 3) {
            // Arrow keys: ESC [ A/B/C/D
            if (inp[2] == 'A') {
                writer.writeAll("Up") catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
            if (inp[2] == 'B') {
                writer.writeAll("Down") catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
            if (inp[2] == 'C') {
                writer.writeAll("Right") catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
            if (inp[2] == 'D') {
                writer.writeAll("Left") catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
            if (inp[2] == 'H') {
                writer.writeAll("Home") catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
            if (inp[2] == 'F') {
                writer.writeAll("End") catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
            // Modified arrows: ESC [ 1 ; <mod> <dir>
            if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';') {
                const mod = inp[4];
                const dir = inp[5];
                // mod: 2=Shift, 3=Alt, 4=Shift+Alt, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=Ctrl+Alt+Shift
                if (mod == '3') writer.writeAll("A-") catch {};
                if (mod == '5') writer.writeAll("C-") catch {};
                if (mod == '7') writer.writeAll("C-A-") catch {};
                const dir_name: []const u8 = switch (dir) {
                    'A' => "Up",
                    'B' => "Down",
                    'C' => "Right",
                    'D' => "Left",
                    else => "?",
                };
                writer.writeAll(dir_name) catch {};
                return .{ .consumed = 6, .text = buf[0..stream.pos] };
            }
            // Skip mouse sequences (ESC [ <)
            if (inp[2] == '<') {
                // Find end of mouse sequence
                var j: usize = 3;
                while (j < inp.len and j < 20) : (j += 1) {
                    if (inp[j] == 'M' or inp[j] == 'm') {
                        return .{ .consumed = j + 1, .text = "" }; // Don't show mouse events
                    }
                }
                return .{ .consumed = inp.len, .text = "" };
            }
            // Other CSI - skip
            return .{ .consumed = 3, .text = "" };
        }

        // SS3 sequence: ESC O (arrow keys on some terminals)
        if (next == 'O' and inp.len >= 3) {
            const dir_name: []const u8 = switch (inp[2]) {
                'A' => "Up",
                'B' => "Down",
                'C' => "Right",
                'D' => "Left",
                'H' => "Home",
                'F' => "End",
                else => "",
            };
            if (dir_name.len > 0) {
                writer.writeAll(dir_name) catch {};
                return .{ .consumed = 3, .text = buf[0..stream.pos] };
            }
        }

        // Alt+key: ESC <char>
        if (next >= 0x20 and next < 0x7f) {
            writer.writeAll("A-") catch {};
            writer.writeByte(next) catch {};
            return .{ .consumed = 2, .text = buf[0..stream.pos] };
        }

        // Ctrl+Alt+key: ESC <ctrl-char>
        if (next >= 0x01 and next <= 0x1a) {
            writer.writeAll("C-A-") catch {};
            writer.writeByte(next + 'a' - 1) catch {};
            return .{ .consumed = 2, .text = buf[0..stream.pos] };
        }

        writer.writeAll("Esc") catch {};
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

    // Control characters
    if (b < 0x20) {
        if (b == 0x0d) {
            writer.writeAll("Enter") catch {};
        } else if (b == 0x09) {
            writer.writeAll("Tab") catch {};
        } else if (b == 0x08) {
            writer.writeAll("Bksp") catch {};
        } else {
            writer.writeAll("C-") catch {};
            writer.writeByte(b + 'a' - 1) catch {};
        }
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

    // Backspace/Delete
    if (b == 0x7f) {
        writer.writeAll("Bksp") catch {};
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

    // Printable ASCII
    if (b >= 0x20 and b < 0x7f) {
        writer.writeByte(b) catch {};
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

    // UTF-8 multi-byte - just show first byte as hex for now
    std.fmt.format(writer, "0x{x:0>2}", .{b}) catch {};
    return .{ .consumed = 1, .text = buf[0..stream.pos] };
}

/// Record input for keycast if enabled
fn recordKeycastInput(state: *State, inp: []const u8) void {
    if (!state.overlays.isKeycastEnabled()) return;
    if (inp.len == 0) return;

    var i: usize = 0;
    while (i < inp.len) {
        var buf: [32]u8 = undefined;
        const result = formatKeycastInput(inp[i..], &buf);
        if (result.text.len > 0) {
            state.overlays.recordKeypress(result.text);
            state.needs_render = true;
        }
        if (result.consumed == 0) break;
        i += result.consumed;
    }
}

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

    // Record all input for keycast display (before any processing)
    recordKeycastInput(state, stable);

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
                                                        const vt_fd = state.ses_client.getVtFd();
                                                        var replaced = true;
                                                        if (vt_fd) |fd| {
                                                            pane.replaceWithPod(result.pane_id, fd, result.uuid) catch {
                                                                replaced = false;
                                                            };
                                                        } else replaced = false;
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

                                // Reply to a pending exit_intent request via SES.
                                if (action == .exit_intent) {
                                    loop_ipc.sendExitIntentResultPub(state, confirmed);
                                    state.pending_exit_intent = false;
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

        // ==========================================================================
        // LEVEL 2.5: Pane select mode - captures all input
        // ==========================================================================
        if (state.overlays.isPaneSelectActive()) {
            // Handle each byte - looking for ESC or label characters
            for (inp) |byte| {
                if (actions.handlePaneSelectInput(state, byte)) {
                    // Input was consumed
                }
            }
            return;
        }

        var i: usize = 0;
        while (i < inp.len) {
            // Inline float title rename mode consumes keyboard input.
            if (state.float_rename_uuid != null) {
                const b = inp[i];

                // Do not intercept SGR mouse sequences.
                if (b == 0x1b and i + 2 < inp.len and inp[i + 1] == '[' and inp[i + 2] == '<') {
                    // Let mouse handler parse it below.
                } else {
                    // ESC cancels.
                    if (b == 0x1b) {
                        state.clearFloatRename();
                        i += 1;
                        continue;
                    }
                    // Enter commits.
                    if (b == '\r') {
                        state.commitFloatRename();
                        i += 1;
                        continue;
                    }
                    // Backspace.
                    if (b == 0x7f or b == 0x08) {
                        if (state.float_rename_buf.items.len > 0) {
                            _ = state.float_rename_buf.pop();
                            state.needs_render = true;
                        }
                        i += 1;
                        continue;
                    }
                    // Printable ASCII.
                    if (b >= 32 and b < 127) {
                        if (state.float_rename_buf.items.len < 64) {
                            state.float_rename_buf.append(state.allocator, b) catch {};
                            state.needs_render = true;
                        }
                        i += 1;
                        continue;
                    }

                    // Ignore everything else while renaming.
                    i += 1;
                    continue;
                }
            }

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
                _ = loop_mouse.handle(state, ev);
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
                    // CSI-u format: ESC [ <digits> [:<digits>] [;<digits>[:<digits>]] u
                    // Only swallow if ALL bytes between ESC[ and 'u' are valid CSI-u chars.
                    if (inp[i + 2] >= '0' and inp[i + 2] <= '9') {
                        var j: usize = i + 2;
                        const end = @min(inp.len, i + 64);
                        var valid_csi_u = true;
                        while (j < end) : (j += 1) {
                            const ch = inp[j];
                            if (ch == 'u') break; // Found terminator
                            // Valid CSI-u intermediate chars: digits, semicolon, colon
                            if ((ch >= '0' and ch <= '9') or ch == ';' or ch == ':') continue;
                            // Any other char means this is NOT a CSI-u sequence
                            valid_csi_u = false;
                            break;
                        }
                        if (valid_csi_u and j < end and inp[j] == 'u') {
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
                    // Check for Ctrl+Alt: ESC followed by control character (0x01-0x1a)
                    if (next >= 0x01 and next <= 0x1a) {
                        // Ctrl+Alt+letter: translate control char back to letter
                        const letter = next + 'a' - 1;
                        if (keybinds.handleKeyEvent(state, 3, .{ .char = letter }, .press, false, false)) {
                            i += 2;
                            continue;
                        }
                    } else {
                        // Plain Alt+key
                        if (keybinds.handleKeyEvent(state, 1, .{ .char = next }, .press, false, false)) {
                            i += 2;
                            continue;
                        }
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

pub fn switchToTab(state: *State, new_tab: usize) void {
    tab_switch.switchToTab(state, new_tab);
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
