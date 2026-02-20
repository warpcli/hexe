const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

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
const loop_input_keys = @import("loop_input_keys.zig");
const loop_mouse = @import("loop_mouse.zig");
const main = @import("main.zig");

const tab_switch = @import("tab_switch.zig");

// Mouse helpers moved to loop_mouse.zig.

// Transitional parser usage: start consuming structured events from libvaxis
// while keeping the existing raw-byte input pipeline intact.
var vaxis_parser: vaxis.Parser = .{};

fn updateInputFlagsFromParser(state: *State, input_bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < input_bytes.len) {
        const result = vaxis_parser.parse(input_bytes[offset..], state.allocator) catch {
            offset += 1;
            continue;
        };
        if (result.n == 0) break;
        offset += result.n;

        if (result.event) |event| {
            switch (event) {
                .paste_start => state.in_bracketed_paste = true,
                .paste_end => state.in_bracketed_paste = false,
                else => {},
            }
        }
    }
}

fn forwardSanitizedToFocusedPane(state: *State, bytes: []const u8) void {
    const ESC: u8 = 0x1b;
    const use_application_arrows = focusedPaneInAltScreen(state);

    var scratch: [8192]u8 = undefined;
    var n: usize = 0;

    const flush = struct {
        fn go(st: *State, buf: *[8192]u8, len: *usize) void {
            if (len.* == 0) return;
            keybinds.forwardInputToFocusedPane(st, buf[0..len.*]);
            len.* = 0;
        }
    }.go;

    var i: usize = 0;
    while (i < bytes.len) {
        if (use_application_arrows and i + 2 < bytes.len and bytes[i] == ESC and bytes[i + 1] == '[') {
            const dir = bytes[i + 2];
            if (dir == 'A' or dir == 'B' or dir == 'C' or dir == 'D') {
                flush(state, &scratch, &n);
                const app_arrow = [3]u8{ ESC, 'O', dir };
                keybinds.forwardInputToFocusedPane(state, &app_arrow);
                i += 3;
                continue;
            }
        }

        if (bytes[i] == ESC and i + 1 < bytes.len and bytes[i + 1] == '[') {
            // Swallow release-only hybrid CSI sequences: ESC [ <num> ; <mod> :3 ~
            if (i + 2 < bytes.len and bytes[i + 2] >= '0' and bytes[i + 2] <= '9') {
                var j: usize = i + 2;
                const end = @min(bytes.len, i + 128);
                var event_type: u8 = 1;
                var has_event = false;
                while (j < end) : (j += 1) {
                    const ch = bytes[j];
                    if (ch == '~') {
                        if (has_event and event_type == 3) {
                            i = j + 1;
                            continue;
                        }
                        break;
                    }
                    if (ch == ':' and j + 1 < end and bytes[j + 1] >= '0' and bytes[j + 1] <= '9') {
                        event_type = bytes[j + 1] - '0';
                        has_event = true;
                        continue;
                    }
                    if ((ch >= '0' and ch <= '9') or ch == ';' or ch == ':') continue;
                    break;
                }
            }

            // Swallow CSI-u shaped sequences to avoid leaking parser transport bytes.
            if (i + 2 < bytes.len and bytes[i + 2] >= '0' and bytes[i + 2] <= '9') {
                var j: usize = i + 2;
                const end = @min(bytes.len, i + 128);
                var valid_csi_u = true;
                while (j < end) : (j += 1) {
                    const ch = bytes[j];
                    if (ch == 'u') break;
                    if ((ch >= '0' and ch <= '9') or ch == ';' or ch == ':') continue;
                    valid_csi_u = false;
                    break;
                }
                if (valid_csi_u and j < end and bytes[j] == 'u') {
                    i = j + 1;
                    continue;
                }
            }
        }

        if (n < scratch.len) {
            scratch[n] = bytes[i];
            n += 1;
        } else {
            flush(state, &scratch, &n);
            scratch[0] = bytes[i];
            n = 1;
        }
        i += 1;
    }

    flush(state, &scratch, &n);
}

fn focusedPaneInAltScreen(state: *State) bool {
    if (state.active_floating) |idx| {
        const fpane = state.floats.items[idx];
        const can_interact = if (fpane.parent_tab) |parent| parent == state.active_tab else true;
        if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
            return fpane.vt.inAltScreen();
        }
    }

    if (state.currentLayout().getFocusedPane()) |pane| {
        return pane.vt.inAltScreen();
    }

    return false;
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

    // Keep bracketed-paste state synchronized from parsed terminal events.
    updateInputFlagsFromParser(state, stable);

    // Record all input for keycast display (before any processing)
    loop_input_keys.recordKeycastInput(state, stable);

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
                                        .pane_close => {
                                            // Close split pane only (not tab).
                                            const layout = state.currentLayout();
                                            if (layout.splitCount() > 1) {
                                                _ = layout.closePane(layout.focused_split_id);
                                                if (layout.getFocusedPane()) |new_pane| {
                                                    state.syncPaneFocus(new_pane, null);
                                                }
                                                state.syncStateToSes();
                                            }
                                        },
                                        else => {},
                                    }
                                } else {
                                    // User cancelled - if exit was from shell death, defer respawn
                                    if (action == .exit and state.exit_from_shell_death) {
                                        state.needs_respawn = true;
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

            // Check for exit_key on focused float (close float if matched).
            const exit_consumed = loop_input_keys.checkExitKey(state, inp[i..]);
            if (exit_consumed > 0) {
                i += exit_consumed;
                continue;
            }

            // Parse key events through libvaxis parser first.
            if (input.parseKeyEvent(inp[i..], state.allocator)) |ev| {
                const event_name: []const u8 = switch (ev.when) {
                    .press => "press",
                    .release => "release",
                    .repeat => "repeat",
                    .hold => "hold",
                };
                main.debugLog("vaxis_mode: key event={s} mods={d}", .{ event_name, ev.mods });

                if (keybinds.handleKeyEvent(state, ev.mods, ev.key, ev.when, false, true)) {
                    i += ev.consumed;
                    continue;
                }

                if (ev.when == .press) {
                    keybinds.forwardKeyToPane(state, ev.mods, ev.key);
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
                    // Handle modified arrows for directional navigation.
                    if (handleAltArrow(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                    // Handle scroll keys.
                    if (handleScrollKeys(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                    // Swallow any CSI sequences ending with arrow terminators (A/B/C/D)
                    // to prevent partial Kitty sequences from leaking to shell.
                    if (swallowCsiArrow(inp[i..])) |consumed| {
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
                        main.debugLog("legacy_mode: Ctrl+Alt+{c}", .{letter});
                        if (keybinds.handleKeyEvent(state, 3, .{ .char = letter }, .press, false, false)) {
                            i += 2;
                            continue;
                        }
                    } else {
                        // Plain Alt+key
                        main.debugLog("legacy_mode: Alt+{c}", .{next});
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

/// Handle modified arrow keys (legacy and Kitty formats).
/// Legacy: ESC [ 1 ; mods A/B/C/D
/// Kitty:  ESC [ 1 ; mods : event A/B/C/D
/// Returns number of bytes consumed, or null if not a modified arrow sequence.
fn handleModifiedArrows(state: *State, inp: []const u8) ?usize {
    // Must start with ESC [ 1 ;
    if (inp.len < 6 or inp[0] != 0x1b or inp[1] != '[' or inp[2] != '1' or inp[3] != ';') return null;

    var idx: usize = 4;

    // Parse modifier value (one or more digits).
    var mod_val: u32 = 0;
    var have_mod = false;
    while (idx < inp.len) : (idx += 1) {
        const ch = inp[idx];
        if (ch >= '0' and ch <= '9') {
            have_mod = true;
            mod_val = mod_val * 10 + @as(u32, ch - '0');
            continue;
        }
        break;
    }
    if (!have_mod or idx >= inp.len) return null;

    // Optional event type after ':'
    var event_type: u8 = 1; // default to press
    if (inp[idx] == ':') {
        idx += 1;
        var ev: u32 = 0;
        var have_ev = false;
        while (idx < inp.len) : (idx += 1) {
            const ch = inp[idx];
            if (ch >= '0' and ch <= '9') {
                have_ev = true;
                ev = ev * 10 + @as(u32, ch - '0');
                continue;
            }
            break;
        }
        if (have_ev) event_type = @intCast(@min(ev, 255));
    }

    if (idx >= inp.len) return null;

    // Check for arrow key terminator
    const key: ?core.Config.BindKey = switch (inp[idx]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        else => null,
    };
    if (key == null) return null;

    // Convert modifier to our format (mask is mod_val - 1)
    const mask: u32 = if (mod_val > 0) mod_val - 1 else 0;
    var mods: u8 = 0;
    if ((mask & 2) != 0) mods |= 1; // alt
    if ((mask & 4) != 0) mods |= 2; // ctrl
    if ((mask & 1) != 0) mods |= 4; // shift

    // Handle press, repeat, and release events for arrow keys
    // Release is needed for tap detection (modified keys defer until release)
    if (event_type >= 1 and event_type <= 3) {
        const when: keybinds.BindWhen = switch (event_type) {
            1 => .press,
            2 => .repeat,
            3 => .release,
            else => .press,
        };
        // Use kitty_mode=true since we have event type info from Kitty protocol
        if (!keybinds.handleKeyEvent(state, mods, key.?, when, false, true)) {
            // No keybind matched - forward arrow key to pane (but not release)
            if (event_type == 1 or event_type == 2) {
                keybinds.forwardKeyToPane(state, mods, key.?);
            }
        }
    }

    return idx + 1;
}

/// Handle Alt+Arrow for directional pane navigation (legacy wrapper).
fn handleAltArrow(state: *State, inp: []const u8) ?usize {
    return handleModifiedArrows(state, inp);
}

/// Swallow modified CSI arrow sequences (with parameters) ending with A/B/C/D.
/// Only swallows sequences like ESC[1;3A, NOT plain ESC[A.
fn swallowCsiArrow(inp: []const u8) ?usize {
    // Must start with ESC [ followed by a digit (modified arrows start with ESC[1;...)
    if (inp.len < 4 or inp[0] != 0x1b or inp[1] != '[') return null;
    // Plain arrows (ESC[A) should NOT be swallowed - they go to the shell
    if (inp[2] == 'A' or inp[2] == 'B' or inp[2] == 'C' or inp[2] == 'D') return null;
    // Must start with a digit
    if (inp[2] < '0' or inp[2] > '9') return null;

    var j: usize = 2;
    const end = @min(inp.len, 64);
    while (j < end) : (j += 1) {
        const ch = inp[j];
        // Valid CSI intermediate chars for arrows: digits, semicolon, colon
        if ((ch >= '0' and ch <= '9') or ch == ';' or ch == ':') continue;
        // Arrow terminators
        if (ch == 'A' or ch == 'B' or ch == 'C' or ch == 'D') {
            return j + 1;
        }
        // Any other char - not an arrow sequence
        break;
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

    // Don't intercept scroll keys in alternate screen mode - let the app handle them
    if (p.vt.inAltScreen()) return null;

    const now = std.time.milliTimestamp();
    const acceleration_timeout_ms: i64 = core.constants.Timing.mouse_acceleration_timeout;

    // PageUp: ESC [ 5 ~ or ESC [ 5 ; <mod> [: <event>] ~
    if (inp.len >= 4 and inp[2] == '5') {
        var j: usize = 3;
        const end = @min(inp.len, 16);
        // Scan to tilde, extracting event type if present
        var event_type: u8 = 1; // default to press
        while (j < end) : (j += 1) {
            if (inp[j] == '~') {
                // Only scroll on press/repeat (not release)
                if (event_type != 3) {
                    // Update acceleration state
                    if (state.last_scroll_key == 5 and (now - state.last_scroll_time_ms) < acceleration_timeout_ms) {
                        state.scroll_repeat_count = @min(state.scroll_repeat_count + 1, 20);
                    } else {
                        state.scroll_repeat_count = 0;
                    }
                    state.last_scroll_key = 5;
                    state.last_scroll_time_ms = now;

                    // Calculate scroll amount with acceleration: 5 + (repeat * 3), max 65 lines
                    const scroll_amount: u32 = @min(5 + (@as(u32, state.scroll_repeat_count) * 3), 65);
                    p.scrollUp(scroll_amount);
                    state.needs_render = true;
                }
                return j + 1;
            }
            if (inp[j] == ':' and j + 1 < end and inp[j + 1] >= '0' and inp[j + 1] <= '9') {
                event_type = inp[j + 1] - '0';
            }
            // Allow digits, semicolon, colon
            if ((inp[j] >= '0' and inp[j] <= '9') or inp[j] == ';' or inp[j] == ':') continue;
            break; // Invalid char
        }
    }

    // PageDown: ESC [ 6 ~ or ESC [ 6 ; <mod> [: <event>] ~
    if (inp.len >= 4 and inp[2] == '6') {
        var j: usize = 3;
        const end = @min(inp.len, 16);
        var event_type: u8 = 1;
        while (j < end) : (j += 1) {
            if (inp[j] == '~') {
                if (event_type != 3) {
                    // Update acceleration state
                    if (state.last_scroll_key == 6 and (now - state.last_scroll_time_ms) < acceleration_timeout_ms) {
                        state.scroll_repeat_count = @min(state.scroll_repeat_count + 1, 20);
                    } else {
                        state.scroll_repeat_count = 0;
                    }
                    state.last_scroll_key = 6;
                    state.last_scroll_time_ms = now;

                    // Calculate scroll amount with acceleration
                    const scroll_amount: u32 = @min(5 + (@as(u32, state.scroll_repeat_count) * 3), 65);
                    p.scrollDown(scroll_amount);
                    state.needs_render = true;
                }
                return j + 1;
            }
            if (inp[j] == ':' and j + 1 < end and inp[j + 1] >= '0' and inp[j + 1] <= '9') {
                event_type = inp[j + 1] - '0';
            }
            if ((inp[j] >= '0' and inp[j] <= '9') or inp[j] == ';' or inp[j] == ':') continue;
            break;
        }
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
