const std = @import("std");
const core = @import("core");

const State = @import("state.zig").State;
const input_csi_u = @import("input_csi_u.zig");
const actions = @import("loop_actions.zig");
const main = @import("main.zig");

/// Parsed exit key with modifiers.
const ParsedExitKey = struct {
    mods: u8, // 1=Alt, 2=Ctrl, 4=Shift
    key: []const u8, // The base key (e.g., "k", "Esc", "Enter")
};

/// Record input for keycast if enabled.
pub fn recordKeycastInput(state: *State, inp: []const u8) void {
    if (!state.overlays.isKeycastEnabled()) return;
    if (inp.len == 0) return;

    // Don't show keycast during bracketed paste
    if (state.in_bracketed_paste) return;

    // Don't show keycast if focused pane might be in password mode
    if (isFocusedPaneInPasswordMode(state)) return;

    var i: usize = 0;
    while (i < inp.len) {
        // Check for bracketed paste start: ESC[200~
        if (i + 5 < inp.len and
            inp[i] == 0x1b and inp[i + 1] == '[' and
            inp[i + 2] == '2' and inp[i + 3] == '0' and
            inp[i + 4] == '0' and inp[i + 5] == '~')
        {
            state.in_bracketed_paste = true;
            return; // Stop recording for the rest of this input
        }

        // Check for bracketed paste end: ESC[201~
        if (i + 5 < inp.len and
            inp[i] == 0x1b and inp[i + 1] == '[' and
            inp[i + 2] == '2' and inp[i + 3] == '0' and
            inp[i + 4] == '1' and inp[i + 5] == '~')
        {
            state.in_bracketed_paste = false;
            i += 6;
            continue;
        }

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

/// Check if input matches a pane's exit_key and close the float if so.
/// Returns bytes consumed if matched, or 0 if no match.
pub fn checkExitKey(state: *State, inp: []const u8) usize {
    const exit_key = getFocusedFloatExitKey(state) orelse return 0;
    if (exit_key.len == 0) return 0;

    const parsed = parseExitKeySpec(exit_key);
    const key_char = getKeyChar(parsed.key) orelse return 0;

    // Match the exit_key against input.
    var consumed: usize = 0;
    const matched = blk: {
        // No modifiers - match raw byte.
        if (parsed.mods == 0) {
            // Special case for Esc: must be standalone (not part of CSI/SS3).
            if (key_char == 0x1b) {
                if (inp.len >= 1 and inp[0] == 0x1b) {
                    if (inp.len == 1 or (inp[1] != '[' and inp[1] != 'O')) {
                        consumed = 1;
                        break :blk true;
                    }
                }
                break :blk false;
            }
            // Other keys: direct byte match.
            if (inp.len >= 1 and inp[0] == key_char) {
                consumed = 1;
                break :blk true;
            }
            break :blk false;
        }

        // Alt only (mods == 1): ESC + char.
        if (parsed.mods == 1) {
            if (inp.len >= 2 and inp[0] == 0x1b) {
                // Make sure it's not a CSI/SS3 sequence.
                if (inp[1] != '[' and inp[1] != 'O') {
                    if (inp[1] == key_char) {
                        consumed = 2;
                        break :blk true;
                    }
                    // Also check lowercase version for letters.
                    if (key_char >= 'A' and key_char <= 'Z') {
                        if (inp[1] == key_char + 32) {
                            consumed = 2;
                            break :blk true;
                        }
                    } else if (key_char >= 'a' and key_char <= 'z') {
                        if (inp[1] == key_char - 32) {
                            consumed = 2;
                            break :blk true;
                        }
                    }
                }
            }
            break :blk false;
        }

        // Ctrl only (mods == 2): control character (0x01-0x1a for a-z).
        if (parsed.mods == 2) {
            if (inp.len >= 1) {
                var ctrl_char: u8 = 0;
                if (key_char >= 'a' and key_char <= 'z') {
                    ctrl_char = key_char - 'a' + 1;
                } else if (key_char >= 'A' and key_char <= 'Z') {
                    ctrl_char = key_char - 'A' + 1;
                }
                if (ctrl_char != 0 and inp[0] == ctrl_char) {
                    consumed = 1;
                    break :blk true;
                }
            }
            break :blk false;
        }

        // Ctrl+Alt (mods == 3): ESC + control character.
        if (parsed.mods == 3) {
            if (inp.len >= 2 and inp[0] == 0x1b) {
                if (inp[1] != '[' and inp[1] != 'O') {
                    var ctrl_char: u8 = 0;
                    if (key_char >= 'a' and key_char <= 'z') {
                        ctrl_char = key_char - 'a' + 1;
                    } else if (key_char >= 'A' and key_char <= 'Z') {
                        ctrl_char = key_char - 'A' + 1;
                    }
                    if (ctrl_char != 0 and inp[1] == ctrl_char) {
                        consumed = 2;
                        break :blk true;
                    }
                }
            }
            break :blk false;
        }

        break :blk false;
    };

    if (matched) {
        main.debugLog("exit_key matched: key={s}", .{exit_key});
        // Mark the float as closed by exit key (for error exit code)
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                state.floats.items[idx].closed_by_exit_key = true;
            }
        }
        actions.performClose(state);
        state.needs_render = true;
        return consumed;
    }

    return 0;
}

/// Check if a CSI-u event matches focused float exit key and close float.
pub fn checkCsiUExitKey(state: *State, ev: input_csi_u.CsiUEvent) bool {
    if (getFocusedFloatExitKey(state)) |exit_key| {
        if (matchesCsiUExitKey(ev, exit_key)) {
            main.debugLog("exit_key matched (CSI-u): key={s}", .{exit_key});
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    state.floats.items[idx].closed_by_exit_key = true;
                }
            }
            actions.performClose(state);
            state.needs_render = true;
            return true;
        }
    }
    return false;
}

/// Format raw input bytes for keycast display.
/// Returns the number of bytes consumed and the formatted text.
fn formatKeycastInput(inp: []const u8, buf: *[32]u8) struct { consumed: usize, text: []const u8 } {
    if (inp.len == 0) return .{ .consumed = 0, .text = "" };

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    const b = inp[0];

    if (b == 0x1b) {
        if (inp.len == 1) {
            writer.writeAll("Esc") catch {};
            return .{ .consumed = 1, .text = buf[0..stream.pos] };
        }

        const next = inp[1];
        if (next == '[' and inp.len >= 3) {
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
            if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';') {
                const mod = inp[4];
                const dir = inp[5];
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
            if (inp[2] == '<') {
                var j: usize = 3;
                while (j < inp.len and j < 20) : (j += 1) {
                    if (inp[j] == 'M' or inp[j] == 'm') {
                        return .{ .consumed = j + 1, .text = "" };
                    }
                }
                return .{ .consumed = inp.len, .text = "" };
            }

            var parse_idx: usize = 2;
            var codepoint: ?u32 = null;
            var modifier: ?u8 = null;
            const cp_start = parse_idx;
            while (parse_idx < inp.len and inp[parse_idx] >= '0' and inp[parse_idx] <= '9') : (parse_idx += 1) {}
            if (parse_idx > cp_start and parse_idx < inp.len and inp[parse_idx] == ';') {
                codepoint = std.fmt.parseInt(u32, inp[cp_start..parse_idx], 10) catch null;
                parse_idx += 1;

                const mod_start = parse_idx;
                while (parse_idx < inp.len and inp[parse_idx] >= '0' and inp[parse_idx] <= '9') : (parse_idx += 1) {}
                if (parse_idx > mod_start) {
                    modifier = std.fmt.parseInt(u8, inp[mod_start..parse_idx], 10) catch null;

                    var event_type: ?u8 = null;
                    if (parse_idx < inp.len and inp[parse_idx] == ':') {
                        parse_idx += 1;
                        const event_start = parse_idx;
                        while (parse_idx < inp.len and inp[parse_idx] >= '0' and inp[parse_idx] <= '9') : (parse_idx += 1) {}
                        if (parse_idx > event_start) {
                            event_type = std.fmt.parseInt(u8, inp[event_start..parse_idx], 10) catch null;
                        }
                    }

                    if (parse_idx < inp.len and inp[parse_idx] == 'u' and codepoint != null and modifier != null) {
                        if (event_type != null and event_type.? == 3) {
                            return .{ .consumed = parse_idx + 1, .text = "" };
                        }
                        const cp = codepoint.?;
                        const mod = modifier.?;

                        if (mod == 3 or mod == 4) writer.writeAll("A-") catch {};
                        if (mod == 5 or mod == 6) writer.writeAll("C-") catch {};
                        if (mod == 7 or mod == 8) writer.writeAll("C-A-") catch {};

                        if (cp >= 32 and cp < 127) {
                            writer.writeByte(@intCast(cp)) catch {};
                        } else {
                            std.fmt.format(writer, "U+{x}", .{cp}) catch {};
                        }

                        return .{ .consumed = parse_idx + 1, .text = buf[0..stream.pos] };
                    }
                }
            }

            var j: usize = 2;
            while (j < inp.len and j < 64) : (j += 1) {
                const ch = inp[j];
                if (ch >= 0x40 and ch <= 0x7e) {
                    return .{ .consumed = j + 1, .text = "" };
                }
            }
            return .{ .consumed = inp.len, .text = "" };
        }

        if (next == ']') {
            var j: usize = 2;
            const BEL: u8 = 0x07;
            while (j < inp.len and j < 1024) : (j += 1) {
                const ch = inp[j];
                if (ch == BEL) return .{ .consumed = j + 1, .text = "" };
                if (ch == 0x1b and j + 1 < inp.len and inp[j + 1] == '\\') {
                    return .{ .consumed = j + 2, .text = "" };
                }
            }
            return .{ .consumed = inp.len, .text = "" };
        }

        if (next == 'O') {
            if (inp.len >= 3) {
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
                return .{ .consumed = 3, .text = "" };
            }
            return .{ .consumed = 1, .text = "Esc" };
        }

        if (next >= 0x20 and next < 0x7f) {
            writer.writeAll("A-") catch {};
            writer.writeByte(next) catch {};
            return .{ .consumed = 2, .text = buf[0..stream.pos] };
        }

        if (next >= 0x01 and next <= 0x1a) {
            writer.writeAll("C-A-") catch {};
            writer.writeByte(next + 'a' - 1) catch {};
            return .{ .consumed = 2, .text = buf[0..stream.pos] };
        }

        writer.writeAll("Esc") catch {};
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

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

    if (b == 0x7f) {
        writer.writeAll("Bksp") catch {};
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

    if (b >= 0x20 and b < 0x7f) {
        writer.writeByte(b) catch {};
        return .{ .consumed = 1, .text = buf[0..stream.pos] };
    }

    std.fmt.format(writer, "0x{x:0>2}", .{b}) catch {};
    return .{ .consumed = 1, .text = buf[0..stream.pos] };
}

fn isFocusedPaneInPasswordMode(state: *State) bool {
    const pane = if (state.active_floating) |idx|
        if (idx < state.floats.items.len) state.floats.items[idx] else return false
    else
        state.currentLayout().getFocusedPane() orelse return false;

    return pane.vt.terminal.flags.password_input;
}

fn getFocusedFloatExitKey(state: *State) ?[]const u8 {
    const idx = state.active_floating orelse return null;
    if (idx >= state.floats.items.len) return null;
    const pane = state.floats.items[idx];
    return pane.exit_key;
}

fn parseExitKeySpec(exit_key: []const u8) ParsedExitKey {
    var mods: u8 = 0;
    var remaining = exit_key;

    while (remaining.len > 0) {
        if (remaining.len > 4 and std.ascii.startsWithIgnoreCase(remaining, "Alt+")) {
            mods |= 1;
            remaining = remaining[4..];
            continue;
        }
        if (remaining.len > 2 and (std.mem.startsWith(u8, remaining, "A-") or std.mem.startsWith(u8, remaining, "a-"))) {
            mods |= 1;
            remaining = remaining[2..];
            continue;
        }
        if (remaining.len > 5 and std.ascii.startsWithIgnoreCase(remaining, "Ctrl+")) {
            mods |= 2;
            remaining = remaining[5..];
            continue;
        }
        if (remaining.len > 2 and (std.mem.startsWith(u8, remaining, "C-") or std.mem.startsWith(u8, remaining, "c-"))) {
            mods |= 2;
            remaining = remaining[2..];
            continue;
        }
        if (remaining.len > 6 and std.ascii.startsWithIgnoreCase(remaining, "Shift+")) {
            mods |= 4;
            remaining = remaining[6..];
            continue;
        }
        if (remaining.len > 2 and (std.mem.startsWith(u8, remaining, "S-") or std.mem.startsWith(u8, remaining, "s-"))) {
            mods |= 4;
            remaining = remaining[2..];
            continue;
        }
        break;
    }

    return .{ .mods = mods, .key = remaining };
}

fn getKeyChar(key: []const u8) ?u8 {
    if (key.len == 0) return null;
    if (key.len == 1) return key[0];
    if (std.ascii.eqlIgnoreCase(key, "Esc") or std.ascii.eqlIgnoreCase(key, "Escape")) return 0x1b;
    if (std.ascii.eqlIgnoreCase(key, "Enter")) return 0x0d;
    if (std.ascii.eqlIgnoreCase(key, "Space")) return ' ';
    if (std.ascii.eqlIgnoreCase(key, "Tab")) return 0x09;
    return null;
}

fn matchesCsiUExitKey(ev: input_csi_u.CsiUEvent, exit_key: []const u8) bool {
    if (ev.event_type != 1) return false;
    if (exit_key.len == 0) return false;

    const parsed = parseExitKeySpec(exit_key);
    if (ev.mods != parsed.mods) return false;

    const key_char = getKeyChar(parsed.key) orelse return false;
    const key_kind = @as(core.Config.BindKeyKind, ev.key);

    if (key_char == ' ') {
        return key_kind == .space;
    }
    return key_kind == .char and ev.key.char == key_char;
}
