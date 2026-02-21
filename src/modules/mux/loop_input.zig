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

const tab_switch = @import("tab_switch.zig");

// Mouse helpers moved to loop_mouse.zig.

// libvaxis parser for structured input events.
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
                .cap_kitty_keyboard => state.renderer.vx.caps.kitty_keyboard = true,
                .cap_kitty_graphics => state.renderer.vx.caps.kitty_graphics = true,
                .cap_rgb => state.renderer.vx.caps.rgb = true,
                .cap_unicode => {
                    state.renderer.vx.caps.unicode = .unicode;
                    state.renderer.vx.screen.width_method = .unicode;
                },
                .cap_sgr_pixels => state.renderer.vx.caps.sgr_pixels = true,
                .cap_color_scheme_updates => state.renderer.vx.caps.color_scheme_updates = true,
                .cap_multi_cursor => state.renderer.vx.caps.multi_cursor = true,
                .cap_da1 => {
                    state.renderer.vx.queries_done.store(true, .unordered);
                    if (!state.terminal_features_enabled) {
                        const stdout = std.fs.File.stdout();
                        var buf: [512]u8 = undefined;
                        var writer = stdout.writer(&buf);
                        state.renderer.vx.enableDetectedFeatures(&writer.interface) catch {};
                        writer.interface.flush() catch {};
                        state.terminal_features_enabled = true;
                    }
                },
                else => {},
            }
        }
    }
}

fn isModifierOnlyKey(cp: u21) bool {
    return cp == vaxis.Key.left_shift or cp == vaxis.Key.left_control or cp == vaxis.Key.left_alt or cp == vaxis.Key.left_super or
        cp == vaxis.Key.right_shift or cp == vaxis.Key.right_control or cp == vaxis.Key.right_alt or cp == vaxis.Key.right_super or
        cp == vaxis.Key.iso_level_3_shift or cp == vaxis.Key.iso_level_5_shift;
}

fn forwardSanitizedToFocusedPane(state: *State, bytes: []const u8, parsed_event: ?vaxis.Event) void {
    keybinds.forwardInputToFocusedPaneWithEvent(state, bytes, parsed_event);
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

fn stashIncompleteParserTail(state: *State, inp: []const u8) []const u8 {
    var i: usize = 0;
    while (i < inp.len) {
        const res = vaxis_parser.parse(inp[i..], state.allocator) catch {
            i += 1;
            continue;
        };

        if (res.n == 0) {
            return stashFromIndex(state, inp, i);
        }
        i += res.n;
    }

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

fn consumeLeadingTerminalQueryReplies(inp: []const u8) []const u8 {
    const ESC: u8 = 0x1b;

    var i: usize = 0;
    while (i + 2 < inp.len and inp[i] == ESC and inp[i + 1] == '[') {
        var j: usize = i + 2;
        while (j < inp.len) : (j += 1) {
            const b = inp[j];
            if (b >= 0x40 and b <= 0x7e) break;
        }
        if (j >= inp.len) break;

        const seq = inp[i .. j + 1];
        const final = seq[seq.len - 1];

        const has_question = std.mem.indexOfScalar(u8, seq, '?') != null;
        const has_semicolon = std.mem.indexOfScalar(u8, seq, ';') != null;
        const has_dollar_y = std.mem.indexOf(u8, seq, "$y") != null;

        // Swallow known terminal probe replies only:
        // - DEC mode reports: ESC[?...$y
        // - CPR replies:       ESC[<row>;<col>R
        // - Kitty/DA replies:  ESC[?...u / ESC[?...c
        const is_query_reply = has_dollar_y or
            (final == 'R' and has_semicolon) or
            (has_question and (final == 'u' or final == 'c'));

        if (!is_query_reply) break;
        i = j + 1;
    }

    return inp[i..];
}

fn handleParsedScrollAction(state: *State, action: input.ScrollAction) bool {
    const pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();
    if (pane == null) return false;

    const p = pane.?;
    if (p.vt.inAltScreen()) return false;

    const now = std.time.milliTimestamp();
    const acceleration_timeout_ms: i64 = core.constants.Timing.mouse_acceleration_timeout;

    switch (action) {
        .page_up => {
            if (state.last_scroll_key == 5 and (now - state.last_scroll_time_ms) < acceleration_timeout_ms) {
                state.scroll_repeat_count = @min(state.scroll_repeat_count + 1, 20);
            } else {
                state.scroll_repeat_count = 0;
            }
            state.last_scroll_key = 5;
            state.last_scroll_time_ms = now;
            const scroll_amount: u32 = @min(5 + (@as(u32, state.scroll_repeat_count) * 3), 65);
            p.scrollUp(scroll_amount);
        },
        .page_down => {
            if (state.last_scroll_key == 6 and (now - state.last_scroll_time_ms) < acceleration_timeout_ms) {
                state.scroll_repeat_count = @min(state.scroll_repeat_count + 1, 20);
            } else {
                state.scroll_repeat_count = 0;
            }
            state.last_scroll_key = 6;
            state.last_scroll_time_ms = now;
            const scroll_amount: u32 = @min(5 + (@as(u32, state.scroll_repeat_count) * 3), 65);
            p.scrollDown(scroll_amount);
        },
        .home => p.scrollToTop(),
        .end => p.scrollToBottom(),
        .shift_up => p.scrollUp(1),
        .shift_down => p.scrollDown(1),
    }

    state.needs_render = true;
    return true;
}

fn handleBlockedPopupInput(popups: anytype, parsed_event: ?vaxis.Event) bool {
    if (parsed_event) |ev| {
        // Reuse already parsed event and avoid reparsing raw bytes.
        return input.handlePopupEvent(popups, ev);
    }
    return false;
}

fn resolveFocusedPaneForInput(state: *State) ?*Pane {
    if (state.active_floating) |idx| {
        const fpane = state.floats.items[idx];
        const can_interact = if (fpane.parent_tab) |parent|
            parent == state.active_tab
        else
            true;
        if (fpane.isVisibleOnTab(state.active_tab) and can_interact) return fpane;
    }
    return state.currentLayout().getFocusedPane();
}

const KeyDispatchResult = enum {
    consumed,
    quit,
    unhandled,
};

const ParsedDispatchResult = struct {
    consumed: bool,
    quit: bool,
    parsed_event: ?vaxis.Event,
    consumed_bytes: usize,
};

fn handleParsedNonKeyEvent(state: *State, ev: vaxis.Event) bool {
    switch (ev) {
        .mouse => |m| {
            _ = loop_mouse.handle(state, m);
            return true;
        },
        .key_press => |k| return isModifierOnlyKey(k.codepoint),
        .key_release => |k| return isModifierOnlyKey(k.codepoint),
        .paste_start,
        .paste_end,
        .focus_in,
        .focus_out,
        .winsize,
        .color_scheme,
        .cap_kitty_keyboard,
        .cap_kitty_graphics,
        .cap_rgb,
        .cap_unicode,
        .cap_sgr_pixels,
        .cap_color_scheme_updates,
        .cap_multi_cursor,
        .cap_da1,
        => return true,
        else => return false,
    }
}

fn dispatchParsedEvent(state: *State, parsed: anytype) ParsedDispatchResult {
    if (parsed.n == 0) return .{ .consumed = false, .quit = false, .parsed_event = null, .consumed_bytes = 0 };
    if (parsed.event == null) return .{ .consumed = true, .quit = false, .parsed_event = null, .consumed_bytes = parsed.n };

    const ev = parsed.event.?;

    if (input.scrollActionFromVaxisEvent(ev)) |action| {
        if (handleParsedScrollAction(state, action)) {
            return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
        }
    }

    if (input.keyEventFromVaxisEvent(ev, parsed.n)) |key_ev| {
        switch (handleParsedKeyEvent(state, key_ev)) {
            .quit => return .{ .consumed = true, .quit = true, .parsed_event = ev, .consumed_bytes = parsed.n },
            .consumed => return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n },
            .unhandled => {},
        }
    }

    if (handleParsedNonKeyEvent(state, ev)) {
        return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
    }

    return .{ .consumed = false, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
}

fn handleParsedKeyEvent(state: *State, ev: input.KeyEvent) KeyDispatchResult {
    if (loop_input_keys.checkExitKeyEvent(state, ev.mods, ev.key, ev.when)) {
        return .consumed;
    }

    if (ev.when == .press and ev.mods == 2 and @as(core.Config.BindKeyKind, ev.key) == .char and ev.key.char == 'q') {
        return .quit;
    }

    if (keybinds.handleKeyEvent(state, ev.mods, ev.key, ev.when, false)) {
        return .consumed;
    }

    // Some terminals collapse Ctrl+Alt+letter into Alt+letter.
    // If Alt variant didn't match, retry as Ctrl+Alt for ASCII letters.
    if (ev.mods == 1 and @as(core.Config.BindKeyKind, ev.key) == .char and ev.when == .press) {
        const ch = ev.key.char;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) {
            if (keybinds.handleKeyEvent(state, ev.mods | 2, ev.key, ev.when, false)) {
                return .consumed;
            }
        }
    }

    if (ev.when == .press) {
        keybinds.forwardKeyToPaneWithText(state, ev.mods, ev.key, ev.text_codepoint);
        return .consumed;
    }

    return .unhandled;
}

pub fn handleInput(state: *State, input_bytes: []const u8) void {
    if (input_bytes.len == 0) return;

    // Stdin reads can split escape sequences. Merge with any pending tail first.
    const merged_res = mergeStdinTail(state, input_bytes);
    defer if (merged_res.owned) |m| state.allocator.free(m);

    const slice = consumeOscReplyFromTerminal(state, merged_res.merged);
    if (slice.len == 0) return;

    // Don't process (or forward) partial parser events.
    const stable = stashIncompleteParserTail(state, slice);
    if (stable.len == 0) return;

    const cleaned = consumeLeadingTerminalQueryReplies(stable);
    if (cleaned.len == 0) return;

    // Keep bracketed-paste state synchronized from parsed terminal events.
    updateInputFlagsFromParser(state, cleaned);

    // Record all input for keycast display (before any processing)
    loop_input_keys.recordKeycastInput(state, cleaned);

    {
        const inp = cleaned;

        // ==========================================================================
        // LEVEL 1: MUX-level popup blocks EVERYTHING
        // ==========================================================================
        if (state.popups.isBlocked()) {
            const parsed_mux = vaxis_parser.parse(inp, state.allocator) catch null;
            const parsed_mux_event: ?vaxis.Event = if (parsed_mux) |p|
                if (p.n > 0) p.event else null
            else
                null;

            if (handleBlockedPopupInput(&state.popups, parsed_mux_event)) {
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
            const parsed_tab = vaxis_parser.parse(inp, state.allocator) catch null;
            const parsed_tab_event: ?vaxis.Event = if (parsed_tab) |p|
                if (p.n > 0) p.event else null
            else
                null;

            // Allow only tab switching while a tab popup is open.
            if (parsed_tab != null and parsed_tab.?.n > 0 and parsed_tab_event != null) {
                if (input.keyEventFromVaxisEvent(parsed_tab_event.?, parsed_tab.?.n)) |ev| {
                    if (keybinds.handleKeyEvent(state, ev.mods, ev.key, ev.when, true)) {
                        return;
                    }
                }
            }
            // Block everything else - handle popup input.
            if (handleBlockedPopupInput(&current_tab.popups, parsed_tab_event)) {
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

            var parsed_event_for_popup: ?vaxis.Event = null;

            // Parse once through libvaxis and dispatch key/scroll/mouse/control.
            const parsed = vaxis_parser.parse(inp[i..], state.allocator) catch null;
            if (parsed) |res| {
                const dispatch = dispatchParsedEvent(state, res);
                parsed_event_for_popup = dispatch.parsed_event;
                if (dispatch.quit) {
                    state.running = false;
                    return;
                }
                if (dispatch.consumed) {
                    i += dispatch.consumed_bytes;
                    continue;
                }
            }

            // ======================================================================
            // LEVEL 3: Focused pane (float or split) popup + input forwarding
            // ======================================================================
            if (resolveFocusedPaneForInput(state)) |pane| {
                if (pane.popups.isBlocked()) {
                    if (handleBlockedPopupInput(&pane.popups, parsed_event_for_popup)) {
                        loop_ipc.sendPopResponse(state);
                    }
                    state.needs_render = true;
                    return;
                }
                if (pane.isScrolled()) {
                    pane.scrollToBottom();
                    state.needs_render = true;
                }
                forwardSanitizedToFocusedPane(state, inp[i..], parsed_event_for_popup);
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
