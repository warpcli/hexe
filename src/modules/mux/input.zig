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
    // Fast gate: SGR mouse sequences start with ESC [ <
    if (input.len < 4 or input[0] != 0x1b or input[1] != '[' or input[2] != '<') return null;

    var parser: vaxis.Parser = .{};
    const parsed = parser.parse(input, std.heap.page_allocator) catch return null;
    if (parsed.n == 0) return null;
    const event = parsed.event orelse return null;

    return switch (event) {
        .mouse => |mouse| mouseEventFromVaxis(mouse, parsed.n),
        else => null,
    };
}

fn mouseEventFromVaxis(mouse: vaxis.Mouse, consumed: usize) MouseEvent {
    var btn: u16 = switch (mouse.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .none => 3,
        .wheel_up => 64,
        .wheel_down => 65,
        .wheel_right => 66,
        .wheel_left => 67,
        .button_8 => 128,
        .button_9 => 129,
        .button_10 => 130,
        .button_11 => 131,
    };

    if (mouse.mods.shift) btn |= 4;
    if (mouse.mods.alt) btn |= 8;
    if (mouse.mods.ctrl) btn |= 16;

    if (mouse.type == .motion or mouse.type == .drag) btn |= 32;

    const x: u16 = if (mouse.col <= 0) 0 else @intCast(mouse.col);
    const y: u16 = if (mouse.row <= 0) 0 else @intCast(mouse.row);

    return .{
        .btn = btn,
        .x = x,
        .y = y,
        .is_release = mouse.type == .release,
        .consumed = consumed,
    };
}
