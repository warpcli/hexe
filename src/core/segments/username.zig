const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Username segment - displays current user
/// Format:  username
pub fn render(ctx: *Context) ?[]const Segment {
    const username = std.posix.getenv("USER") orelse std.posix.getenv("LOGNAME") orelse return null;

    const text = ctx.allocFmt(" {s}", .{username}) catch return null;

    // Use different style for root
    const style = if (std.mem.eql(u8, username, "root"))
        Style.parse("bold fg:red")
    else
        Style.parse("fg:green");

    return ctx.addSegment(text, style) catch return null;
}
