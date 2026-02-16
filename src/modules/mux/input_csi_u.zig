const std = @import("std");

const core = @import("core");

const State = @import("state.zig").State;
const keybinds = @import("keybinds.zig");

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

pub const CsiUEvent = struct {
    consumed: usize,
    mods: u8,
    key: core.Config.BindKey,
    event_type: u8, // 1 press, 2 repeat, 3 release
};

/// Parse a kitty-style CSI-u key event without enabling the protocol.
///
/// Some external layers can inject CSI-u sequences. We treat them as a transport
/// for (mods,key) only, and never forward the raw sequence into the child PTY.
///
/// Format (subset):
///   ESC [ keycode[:alt...] ; modifiers[:event] [;text] u
/// We only accept ASCII keycodes and the modifiers field.
pub fn parse(inp: []const u8) ?CsiUEvent {
    if (inp.len < 4) return null;
    if (inp[0] != 0x1b or inp[1] != '[') return null;

    var idx: usize = 2;
    var keycode: u32 = 0;
    var have_digit = false;
    while (idx < inp.len) : (idx += 1) {
        const ch = inp[idx];
        if (ch >= '0' and ch <= '9') {
            have_digit = true;
            keycode = keycode * 10 + @as(u32, ch - '0');
            continue;
        }
        break;
    }
    if (!have_digit or idx >= inp.len) return null;

    // Optional alternate keycodes after ':'; ignore.
    if (inp[idx] == ':') {
        while (idx < inp.len and inp[idx] != ';' and inp[idx] != 'u') : (idx += 1) {}
        if (idx >= inp.len) return null;
    }

    var mod_val: u32 = 1;
    var event_type: u32 = 1;

    if (inp[idx] == 'u') {
        idx += 1;
    } else if (inp[idx] == ';') {
        idx += 1;

        // Modifiers can be empty.
        var mv: u32 = 0;
        var have_mv = false;
        while (idx < inp.len) : (idx += 1) {
            const ch = inp[idx];
            if (ch >= '0' and ch <= '9') {
                have_mv = true;
                mv = mv * 10 + @as(u32, ch - '0');
                continue;
            }
            break;
        }
        if (have_mv) mod_val = mv;

        // Optional event type as sub-field of modifiers.
        if (idx < inp.len and inp[idx] == ':') {
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
            if (have_ev) event_type = ev;
        }

        // Optional third field; ignore but consume.
        if (idx < inp.len and inp[idx] == ';') {
            idx += 1;
            while (idx < inp.len and inp[idx] != 'u') : (idx += 1) {}
        }

        if (idx >= inp.len or inp[idx] != 'u') return null;
        idx += 1;
    } else {
        return null;
    }

    const mask: u32 = if (mod_val > 0) mod_val - 1 else 0;
    var mods: u8 = 0;
    if ((mask & 2) != 0) mods |= 1; // alt
    if ((mask & 4) != 0) mods |= 2; // ctrl
    if ((mask & 1) != 0) mods |= 4; // shift
    if ((mask & 8) != 0) mods |= 8; // super

    const key: core.Config.BindKey = blk: {
        if (keycode == 32) break :blk .space;
        if (keycode <= 0x7f) break :blk .{ .char = @intCast(keycode) };
        return null;
    };

    return .{ .consumed = idx, .mods = mods, .key = key, .event_type = @intCast(@min(255, event_type)) };
}

pub fn translateToLegacy(out: *[8]u8, ev: CsiUEvent) ?usize {
    var ch: u8 = switch (@as(core.Config.BindKeyKind, ev.key)) {
        .space => ' ',
        .char => ev.key.char,
        else => return null,
    };

    // Shift+Tab = backtab (CSI Z)
    if ((ev.mods & 4) != 0 and ch == 0x09) {
        out[0] = 0x1b;
        out[1] = '[';
        out[2] = 'Z';
        return 3;
    }

    // Ctrl+Space = NUL
    if ((ev.mods & 2) != 0 and ch == ' ') {
        out[0] = 0x00;
        return 1;
    }

    if ((ev.mods & 4) != 0) {
        if (ch >= 'a' and ch <= 'z') ch = ch - 'a' + 'A';
    }
    if ((ev.mods & 2) != 0) {
        if (ch >= 'a' and ch <= 'z') {
            ch = ch - 'a' + 1;
        } else if (ch >= 'A' and ch <= 'Z') {
            ch = ch - 'A' + 1;
        }
    }

    var n: usize = 0;
    if ((ev.mods & 1) != 0) {
        out[n] = 0x1b;
        n += 1;
    }
    out[n] = ch;
    n += 1;
    return n;
}

pub fn forwardSanitizedToFocusedPane(state: *State, bytes: []const u8) void {
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
        // In alternate screen mode, map plain CSI arrows to SS3 arrows
        // (application cursor mode) for better ncurses compatibility.
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
            if (parse(bytes[i..])) |ev| {
                // Drop release, translate others.
                if (ev.event_type != 3) {
                    var out: [8]u8 = undefined;
                    if (translateToLegacy(&out, ev)) |out_len| {
                        flush(state, &scratch, &n);
                        keybinds.forwardInputToFocusedPane(state, out[0..out_len]);
                    }
                }
                i += ev.consumed;
                continue;
            }

            // Handle hybrid sequences: ESC [ <num> ; <mod> [:<event>] ~
            // These are traditional sequences (like PageUp=5~) with CSI-u event types
            // Format: ESC [ <digits> ; <modifier> [: <event_type>] ~
            if (i + 2 < bytes.len and bytes[i + 2] >= '0' and bytes[i + 2] <= '9') {
                var j: usize = i + 2;
                const end = @min(bytes.len, i + 128);
                var found_semicolon = false;
                var found_colon = false;
                var event_type: u8 = 1; // default to press

                // Scan for pattern: digits ; digits [:digits] ~
                while (j < end) : (j += 1) {
                    const ch = bytes[j];
                    if (ch == '~') {
                        // Found tilde terminator - filter by event type
                        // Only swallow release events (event_type == 3)
                        if (event_type != 3) {
                            // Strip event type and forward as traditional sequence
                            // Convert ESC[5;1:3~ to ESC[5~, or ESC[5~ as-is
                            const colon_pos = std.mem.indexOf(u8, bytes[i .. j + 1], ":");
                            const semi_pos = std.mem.indexOf(u8, bytes[i .. j + 1], ";");

                            if (colon_pos != null or semi_pos != null) {
                                // Has modifiers/event type - strip them, keep just keycode~
                                // Find end of keycode (before semicolon)
                                var keycode_end = i + 2;
                                while (keycode_end < j and bytes[keycode_end] >= '0' and bytes[keycode_end] <= '9') : (keycode_end += 1) {}
                                flush(state, &scratch, &n);
                                // Forward: ESC [ <keycode> ~
                                keybinds.forwardInputToFocusedPane(state, bytes[i..keycode_end]);
                                keybinds.forwardInputToFocusedPane(state, "~");
                            } else {
                                // Plain sequence, no modifiers - forward as-is
                                flush(state, &scratch, &n);
                                keybinds.forwardInputToFocusedPane(state, bytes[i .. j + 1]);
                            }
                        }
                        i = j + 1;
                        break;
                    }
                    if (ch == ';') {
                        found_semicolon = true;
                        continue;
                    }
                    if (ch == ':') {
                        found_colon = true;
                        // Parse event type after colon
                        if (j + 1 < end and bytes[j + 1] >= '0' and bytes[j + 1] <= '9') {
                            event_type = bytes[j + 1] - '0';
                        }
                        continue;
                    }
                    if ((ch >= '0' and ch <= '9')) continue;
                    // Invalid char - not a hybrid sequence
                    break;
                }
                if (j < end and bytes[j] == '~') continue; // Already handled above
            }

            // Last-resort: swallow CSI-u shaped sequences (ESC [ <digits...> u).
            // CSI-u format: ESC [ <digits> [:<digits>] [;<digits>[:<digits>]] u
            // Only swallow if ALL bytes between ESC[ and 'u' are valid CSI-u chars.
            if (i + 2 < bytes.len and bytes[i + 2] >= '0' and bytes[i + 2] <= '9') {
                var j: usize = i + 2;
                const end = @min(bytes.len, i + 128);
                var valid_csi_u = true;
                while (j < end) : (j += 1) {
                    const ch = bytes[j];
                    if (ch == 'u') break; // Found terminator
                    // Valid CSI-u intermediate chars: digits, semicolon, colon
                    if ((ch >= '0' and ch <= '9') or ch == ';' or ch == ':') continue;
                    // Any other char means this is NOT a CSI-u sequence
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
        }
        i += 1;
    }
    flush(state, &scratch, &n);
}
