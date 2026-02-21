const std = @import("std");
const core = @import("core");
const vaxis = @import("vaxis");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const SesClient = @import("ses_client.zig").SesClient;

const input = @import("input.zig");

const actions = @import("loop_actions.zig");
const loop_ipc = @import("loop_ipc.zig");
const keybinds = @import("keybinds.zig");
const loop_input_keys = @import("loop_input_keys.zig");
const loop_mouse = @import("loop_mouse.zig");

const tab_switch = @import("tab_switch.zig");

// Mouse helpers moved to loop_mouse.zig.

// libvaxis parser for structured input events.
var vaxis_parser: vaxis.Parser = .{};

const ParsedEventHead = struct {
    n: usize,
    event: ?vaxis.Event,
};

fn parseEventHead(state: *State, bytes: []const u8) ?ParsedEventHead {
    const parsed = vaxis_parser.parse(bytes, state.allocator) catch return null;
    if (parsed.n == 0) return null;
    return .{ .n = parsed.n, .event = parsed.event };
}

fn applyQueryProbeKeyFlags(state: *State, key: vaxis.Key) void {
    if (!state.terminal_query_in_flight) return;
    if (key.codepoint != vaxis.Key.f3) return;

    // libvaxis probe path encodes explicit-width and scaled-text detection via
    // modified F3 key parses while query mode is active.
    if (key.mods.shift) state.renderer.vx.caps.explicit_width = true;
    if (key.mods.alt) state.renderer.vx.caps.scaled_text = true;
}

fn applyInputFlagsForEvent(state: *State, event: vaxis.Event) void {
    switch (event) {
        .key_press => |k| applyQueryProbeKeyFlags(state, k),
        .key_release => |k| applyQueryProbeKeyFlags(state, k),
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
        },
        else => {},
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

fn forwardPasteToFocusedPane(state: *State, txt: []const u8) void {
    if (txt.len == 0) return;

    if (resolveFocusedPaneForInput(state)) |pane| {
        if (pane.popups.isBlocked()) return;
        if (pane.isScrolled()) {
            pane.scrollToBottom();
            state.needs_render = true;
        }
        pane.write(txt) catch {};
    }
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

fn handleMuxLevelPopup(state: *State, parsed_event: ?vaxis.Event) bool {
    if (!state.popups.isBlocked()) return false;

    if (handleBlockedPopupInput(&state.popups, parsed_event)) {
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
    return true;
}

fn handleTabLevelPopup(state: *State, parsed_event: ?vaxis.Event) bool {
    const current_tab = &state.tabs.items[state.active_tab];
    if (!current_tab.popups.isBlocked()) return false;

    // Allow only tab switching while a tab popup is open.
    if (parsed_event) |ev_raw| {
        if (input.keyEventFromVaxisEvent(ev_raw)) |ev| {
            if (keybinds.handleKeyEvent(state, ev.mods, ev.key, ev.when, true)) {
                return true;
            }
        }
    }

    // Block everything else - handle popup input.
    if (handleBlockedPopupInput(&current_tab.popups, parsed_event)) {
        loop_ipc.sendPopResponse(state);
    }
    state.needs_render = true;
    return true;
}

fn appendFloatRenameText(state: *State, text: []const u8) void {
    if (text.len == 0) return;
    const max_len: usize = 64;
    if (state.float_rename_buf.items.len >= max_len) return;
    const remaining = max_len - state.float_rename_buf.items.len;
    if (text.len > remaining) return;
    state.float_rename_buf.appendSlice(state.allocator, text) catch return;
    state.needs_render = true;
}

fn handleFloatRenameParsedEvent(state: *State, parsed: ParsedEventHead) bool {
    if (state.float_rename_uuid == null) return false;

    const event = parsed.event orelse return true;
    return switch (event) {
        .mouse => false,
        .key_release => true,
        .key_press => |k| blk: {
            switch (k.codepoint) {
                vaxis.Key.escape => {
                    state.clearFloatRename();
                    break :blk true;
                },
                vaxis.Key.enter => {
                    state.commitFloatRename();
                    break :blk true;
                },
                vaxis.Key.backspace => {
                    if (state.float_rename_buf.items.len > 0) {
                        _ = state.float_rename_buf.pop();
                        state.needs_render = true;
                    }
                    break :blk true;
                },
                else => {},
            }

            if (k.text) |txt| {
                appendFloatRenameText(state, txt);
                break :blk true;
            }

            const cp = k.base_layout_codepoint orelse k.codepoint;
            if (cp >= 32 and cp < 127) {
                const b: u8 = @intCast(cp);
                appendFloatRenameText(state, &.{b});
            }
            break :blk true;
        },
        else => true,
    };
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
        .paste => |txt| {
            defer state.allocator.free(txt);
            forwardPasteToFocusedPane(state, txt);
            return true;
        },
        .key_press => |k| return isModifierOnlyKey(k.codepoint),
        .key_release => |k| return isModifierOnlyKey(k.codepoint),
        .paste_start,
        .paste_end,
        .color_report,
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
    applyInputFlagsForEvent(state, ev);

    if (input.scrollActionFromVaxisEvent(ev)) |action| {
        if (handleParsedScrollAction(state, action)) {
            return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
        }
    }

    if (input.keyEventFromVaxisEvent(ev)) |key_ev| {
        switch (handleParsedKeyEvent(state, key_ev)) {
            .quit => return .{ .consumed = true, .quit = true, .parsed_event = ev, .consumed_bytes = parsed.n },
            .consumed => return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n },
            .unhandled => {
                // Never forward parser key-release bytes to panes.
                if (key_ev.when == .release) {
                    return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
                }
            },
        }
    }

    if (handleParsedNonKeyEvent(state, ev)) {
        return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
    }

    // Parser-first policy: never forward decoded-but-unmapped events as raw bytes.
    return .{ .consumed = true, .quit = false, .parsed_event = ev, .consumed_bytes = parsed.n };
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

fn firstOrParseAt(state: *State, inp: []const u8, offset: usize, first: ?ParsedEventHead) ?ParsedEventHead {
    if (offset == 0) return first;
    return parseEventHead(state, inp[offset..]);
}

fn handlePaneSelectLoop(state: *State, inp: []const u8, first_parsed: ?ParsedEventHead) void {
    var i: usize = 0;
    while (i < inp.len) {
        const parsed = firstOrParseAt(state, inp, i, first_parsed);
        if (parsed) |res| {
            i += res.n;
            _ = actions.handlePaneSelectEvent(state, res.event);
            continue;
        }

        // Keep pane-select mode isolated on parser failures.
        i += 1;
    }
}

fn handleFocusedInputLoop(state: *State, inp: []const u8, first_parsed: ?ParsedEventHead) void {
    var i: usize = 0;
    while (i < inp.len) {
        var parsed_event_for_popup: ?vaxis.Event = null;

        // Parse once through libvaxis and dispatch key/scroll/mouse/control.
        const parsed = firstOrParseAt(state, inp, i, first_parsed);
        if (parsed) |res| {
            if (handleFloatRenameParsedEvent(state, res)) {
                i += res.n;
                continue;
            }

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
        } else {
            // Parser-first policy: never forward undecoded bytes.
            // Keep rename mode isolated and drop unknown bytes in normal mode.
            i += 1;
            continue;
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

fn clearOscReplyCapture(state: *State) void {
    state.osc_reply_in_progress = false;
    state.osc_reply_prev_esc = false;
    state.osc_reply_target_uuid = null;
    state.osc_reply_buf.clearRetainingCapacity();
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

    // Record all input for keycast display (before any processing)
    loop_input_keys.recordKeycastInput(state, stable);

    const inp = stable;

    const first_parsed = parseEventHead(state, inp);
    const popup_event: ?vaxis.Event = if (first_parsed) |h| h.event else null;

    if (handleMuxLevelPopup(state, popup_event)) return;
    if (handleTabLevelPopup(state, popup_event)) return;

    // ==========================================================================
    // LEVEL 2.5: Pane select mode - captures all input
    // ==========================================================================
    if (state.overlays.isPaneSelectActive()) {
        handlePaneSelectLoop(state, inp, first_parsed);
        return;
    }

    handleFocusedInputLoop(state, inp, first_parsed);
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
            clearOscReplyCapture(state);
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
            clearOscReplyCapture(state);
            return inp[i + 1 ..];
        }

        if (done) {
            if (state.osc_reply_target_uuid) |uuid| {
                if (state.findPaneByUuid(uuid)) |pane| {
                    pane.write(state.osc_reply_buf.items) catch {};
                }
            }

            clearOscReplyCapture(state);

            return inp[i + 1 ..];
        }
    }

    // Consumed everything into the pending reply buffer.
    return &[_]u8{};
}
