const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Pod name segment - displays HEXE_POD_NAME environment variable
pub fn render(ctx: *Context) ?[]const Segment {
    const pod_name = std.posix.getenv("HEXE_POD_NAME") orelse return null;
    if (pod_name.len == 0) return null;

    const text = ctx.allocText(pod_name) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}
