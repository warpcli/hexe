const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Status segment - displays last command exit code if non-zero
/// Format: ✗ 127
pub fn render(ctx: *Context) ?[]const Segment {
    const exit_status = ctx.exit_status orelse return null;

    // Only show if non-zero
    if (exit_status == 0) return null;

    const text = ctx.allocFmt("✗ {d}", .{exit_status}) catch return null;

    return ctx.addSegment(text, Style.parse("bold fg:red")) catch return null;
}
