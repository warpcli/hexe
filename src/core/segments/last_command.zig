const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Last command segment - shows the last executed command line.
/// Intended for mux statusbar usage.
pub fn render(ctx: *Context) ?[]const Segment {
    const cmd0 = ctx.last_command orelse return null;
    const cmd = std.mem.trim(u8, cmd0, " \t\n\r");
    if (cmd.len == 0) return null;

    // Keep it short for status bars.
    const max_len: usize = 32;
    const shown = if (cmd.len > max_len) blk: {
        const cut = max_len - 3;
        break :blk ctx.allocFmt("{s}...", .{cmd[0..cut]}) catch return null;
    } else ctx.allocText(cmd) catch return null;

    return ctx.addSegment(shown, Style.parse("fg:7")) catch return null;
}
