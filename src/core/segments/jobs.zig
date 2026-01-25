const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Jobs segment - displays background job count
/// Format: ✦2
pub fn render(ctx: *Context) ?[]const Segment {
    if (ctx.jobs == 0) return null;

    const text = ctx.allocFmt("✦{d}", .{ctx.jobs}) catch return null;

    return ctx.addSegment(text, Style.parse("fg:blue")) catch return null;
}
