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
    text_codepoint: ?u21,
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

pub fn parseKeyEvent(input_bytes: []const u8, allocator: std.mem.Allocator) ?KeyEvent {
    if (input_bytes.len == 0) return null;

    var parser: vaxis.Parser = .{};
    const parsed = parser.parse(input_bytes, allocator) catch return null;
    if (parsed.n == 0) return null;
    const event = parsed.event orelse return null;

    return keyEventFromVaxisEvent(event, parsed.n);
}

pub fn keyEventFromVaxisEvent(event: vaxis.Event, consumed: usize) ?KeyEvent {
    return switch (event) {
        .key_press => |key| parseVaxisKey(key, .press, consumed),
        .key_release => |key| parseVaxisKey(key, .release, consumed),
        else => null,
    };
}

pub fn scrollActionFromVaxisEvent(event: vaxis.Event) ?ScrollAction {
    const key = switch (event) {
        .key_press => |k| k,
        else => return null,
    };

    return switch (key.codepoint) {
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.up => if (key.mods.shift) .shift_up else null,
        vaxis.Key.down => if (key.mods.shift) .shift_down else null,
        else => null,
    };
}

fn parseVaxisKey(vk: vaxis.Key, when: core.Config.BindWhen, consumed: usize) ?KeyEvent {
    var mods = modsMaskFromVaxis(vk.mods);
    const bind_key = vaxisKeyToBindKey(vk, &mods) orelse return null;
    const text_cp = textCodepointForForwarding(vk);
    return .{
        .mods = mods,
        .key = bind_key,
        .text_codepoint = text_cp,
        .when = when,
        .consumed = consumed,
    };
}

fn textCodepointForForwarding(vk: vaxis.Key) ?u21 {
    // Prefer parser-provided text when available. This preserves shifted
    // punctuation (e.g. ':' vs ';') and non-ASCII text input.
    if (vk.text) |txt| {
        var view = std.unicode.Utf8View.init(txt) catch return null;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return null;
        if (it.nextCodepoint() != null) return null;
        if (cp < 0x20 or cp == 0x7f) return null;
        if (cp >= 0x80 and cp <= 0x9f) return null;
        if (cp <= 0x10ffff) return cp;
    }

    // Fallback to shifted codepoint when available.
    if (vk.shifted_codepoint) |cp_shifted| {
        if (cp_shifted >= 0x20 and cp_shifted != 0x7f and !(cp_shifted >= 0x80 and cp_shifted <= 0x9f) and cp_shifted <= 0x10ffff) {
            return cp_shifted;
        }
    }

    const cp = vk.codepoint;
    if (cp < 0x20 or cp == 0x7f) return null;
    if (cp >= 0x80 and cp <= 0x9f) return null;
    if (cp > 0x10ffff) return null;
    return cp;
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

pub fn mouseEventFromVaxis(mouse: vaxis.Mouse, consumed: usize) MouseEvent {
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
