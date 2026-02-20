const std = @import("std");
const core = @import("core");
const pop = @import("pop");
const vaxis = @import("vaxis");

const Pane = @import("pane.zig").Pane;

/// Handle popup input and return true if popup was dismissed
pub fn handlePopupInput(popups: *pop.PopupManager, input: []const u8) bool {
    const key = parsePopupKey(input) orelse return false;
    const result = popups.handleInput(key);
    return result == .dismissed;
}

fn parsePopupKey(input: []const u8) ?u8 {
    if (input.len == 0) return null;

    var parser: vaxis.Parser = .{};
    const parsed = parser.parse(input, std.heap.page_allocator) catch return null;
    if (parsed.n == 0) return null;
    const event = parsed.event orelse return null;

    const key = switch (event) {
        .key_press => |k| k,
        else => return null,
    };

    return switch (key.codepoint) {
        vaxis.Key.up => 'k',
        vaxis.Key.down => 'j',
        vaxis.Key.left => 'h',
        vaxis.Key.right => 'l',
        vaxis.Key.enter => '\r',
        vaxis.Key.escape => 27,
        else => blk: {
            const cp = key.base_layout_codepoint orelse key.codepoint;
            if (cp > 0xFF) break :blk null;
            break :blk @intCast(cp);
        },
    };
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

pub const ScrollAction = enum {
    page_up,
    page_down,
    home,
    end,
    shift_up,
    shift_down,
};

pub const ScrollEvent = struct {
    action: ScrollAction,
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

/// Consume non-key parser transport/control sequences so they don't leak to pane stdin.
/// Returns consumed byte count when sequence should be swallowed.
pub fn parseTransportSequence(input_bytes: []const u8, allocator: std.mem.Allocator) ?usize {
    if (input_bytes.len == 0) return null;
    if (input_bytes[0] != 0x1b) return null;

    var parser: vaxis.Parser = .{};
    const parsed = parser.parse(input_bytes, allocator) catch return null;
    if (parsed.n == 0) return null;

    if (parsed.event == null) return parsed.n;

    return switch (parsed.event.?) {
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
        => parsed.n,
        else => null,
    };
}

pub fn parseScrollEvent(input_bytes: []const u8, allocator: std.mem.Allocator) ?ScrollEvent {
    if (input_bytes.len == 0) return null;

    var parser: vaxis.Parser = .{};
    const parsed = parser.parse(input_bytes, allocator) catch return null;
    if (parsed.n == 0) return null;
    const event = parsed.event orelse return null;

    const key = switch (event) {
        .key_press => |k| k,
        else => return null,
    };

    const action: ScrollAction = switch (key.codepoint) {
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.up => if (key.mods.shift) .shift_up else return null,
        vaxis.Key.down => if (key.mods.shift) .shift_down else return null,
        else => return null,
    };

    return .{ .action = action, .consumed = parsed.n };
}

fn parseVaxisKey(vk: vaxis.Key, when: core.Config.BindWhen, consumed: usize) ?KeyEvent {
    var mods = modsMaskFromVaxis(vk.mods);
    const bind_key = vaxisKeyToBindKey(vk, &mods) orelse return null;
    return .{
        .mods = mods,
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

fn vaxisKeyToBindKey(vk: vaxis.Key, mods_inout: *u8) ?core.Config.BindKey {
    return switch (vk.codepoint) {
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.space => .space,
        else => blk: {
            var cp: u21 = vk.base_layout_codepoint orelse vk.codepoint;

            // Normalize Ctrl+letter control bytes (0x01..0x1A) to a-z.
            if (cp >= 1 and cp <= 26) {
                cp = 'a' + (cp - 1);
                mods_inout.* |= 2;
            }

            // Match config key style: use lowercase alpha key + shift mod.
            if (cp >= 'A' and cp <= 'Z') {
                cp = std.ascii.toLower(@intCast(cp));
                mods_inout.* |= 4;
            }

            if (cp > 0xFF) break :blk null;
            break :blk .{ .char = @intCast(cp) };
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
