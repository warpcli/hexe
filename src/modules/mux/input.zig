const std = @import("std");
const core = @import("core");
const pop = @import("pop");
const vaxis = @import("vaxis");

const Pane = @import("pane.zig").Pane;

/// Convert arrow key escape sequences to vim-style keys for popup navigation
pub fn convertArrowKey(input: []const u8) u8 {
    if (input.len == 0) return 0;
    // Check for ESC sequences
    if (input[0] == 0x1b) {
        // Arrow keys: ESC [ A/B/C/D
        if (input.len >= 3 and input[1] == '[') {
            return switch (input[2]) {
                'C' => 'l', // Right arrow -> toggle
                'D' => 'h', // Left arrow -> toggle
                'A' => 'k', // Up arrow -> up (picker)
                'B' => 'j', // Down arrow -> down (picker)
                else => 0, // Ignore other CSI sequences
            };
        }
        // Alt+key: ESC followed by printable char (not '[' or 'O')
        // Ignore these - return 0
        if (input.len >= 2 and input[1] != '[' and input[1] != 'O') {
            return 0; // Ignore Alt+key
        }
        // Bare ESC key (no following char, or timeout)
        return 27; // ESC to cancel
    }
    return input[0];
}

/// Handle popup input and return true if popup was dismissed
pub fn handlePopupInput(popups: *pop.PopupManager, input: []const u8) bool {
    const key = convertArrowKey(input);
    const result = popups.handleInput(key);
    return result == .dismissed;
}

/// Parse SGR mouse event from input
/// Returns mouse event info or null if not a mouse event
pub const MouseEvent = struct {
    btn: u16,
    x: u16,
    y: u16,
    is_release: bool,
    consumed: usize,
};

pub const KeyEvent = struct {
    mods: u8,
    key: core.Config.BindKey,
    when: core.Config.BindWhen,
    consumed: usize,
};

pub fn parseKeyEvent(input_bytes: []const u8, allocator: std.mem.Allocator) ?KeyEvent {
    if (input_bytes.len == 0) return null;

    var parser: vaxis.Parser = .{};
    const parsed = parser.parse(input_bytes, allocator) catch return null;
    if (parsed.n == 0) return null;
    const event = parsed.event orelse return null;

    return switch (event) {
        .key_press => |key| parseVaxisKey(key, .press, parsed.n),
        .key_release => |key| parseVaxisKey(key, .release, parsed.n),
        else => null,
    };
}

fn parseVaxisKey(vk: vaxis.Key, when: core.Config.BindWhen, consumed: usize) ?KeyEvent {
    const bind_key = vaxisKeyToBindKey(vk) orelse return null;
    return .{
        .mods = modsMaskFromVaxis(vk.mods),
        .key = bind_key,
        .when = when,
        .consumed = consumed,
    };
}

fn modsMaskFromVaxis(mods: vaxis.Key.Modifiers) u8 {
    var out: u8 = 0;
    if (mods.alt) out |= 1;
    if (mods.ctrl) out |= 2;
    if (mods.shift) out |= 4;
    if (mods.super) out |= 8;
    return out;
}

fn vaxisKeyToBindKey(vk: vaxis.Key) ?core.Config.BindKey {
    return switch (vk.codepoint) {
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.space => .space,
        else => blk: {
            if (vk.codepoint > 0xFF) break :blk null;
            break :blk .{ .char = @intCast(vk.codepoint) };
        },
    };
}

pub fn parseMouseEvent(input: []const u8) ?MouseEvent {
    // Must start with ESC [ <
    if (input.len < 4 or input[0] != 0x1b or input[1] != '[' or input[2] != '<') return null;

    // Find the 'M' or 'm' terminator
    var end: usize = 3;
    while (end < input.len and input[end] != 'M' and input[end] != 'm') : (end += 1) {}
    if (end >= input.len) return null;

    const is_release = input[end] == 'm';

    // Parse: btn ; x ; y
    var btn: u16 = 0;
    var mouse_x: u16 = 0;
    var mouse_y: u16 = 0;
    var field: u8 = 0;
    var i: usize = 3;
    while (i < end) : (i += 1) {
        if (input[i] == ';') {
            field += 1;
        } else if (input[i] >= '0' and input[i] <= '9') {
            const digit = input[i] - '0';
            switch (field) {
                0 => btn = btn * 10 + digit,
                1 => mouse_x = mouse_x * 10 + digit,
                2 => mouse_y = mouse_y * 10 + digit,
                else => {},
            }
        }
    }

    // Convert from 1-based to 0-based coordinates
    if (mouse_x > 0) mouse_x -= 1;
    if (mouse_y > 0) mouse_y -= 1;

    return MouseEvent{
        .btn = btn,
        .x = mouse_x,
        .y = mouse_y,
        .is_release = is_release,
        .consumed = end + 1,
    };
}
