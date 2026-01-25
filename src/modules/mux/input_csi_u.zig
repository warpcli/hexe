const std = @import("std");

const core = @import("core");

const State = @import("state.zig").State;
const keybinds = @import("keybinds.zig");

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

            // Last-resort: swallow CSI-u shaped sequences (ESC [ <digits...> u).
            if (i + 2 < bytes.len and bytes[i + 2] >= '0' and bytes[i + 2] <= '9') {
                var j: usize = i + 2;
                const end = @min(bytes.len, i + 128);
                while (j < end and bytes[j] != 'u') : (j += 1) {}
                if (j < end and bytes[j] == 'u') {
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
