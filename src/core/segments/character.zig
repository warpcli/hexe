const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Character segment - prompt character that changes color based on exit status
/// Format: ❯ (green on success, red on error)
pub fn render(ctx: *Context) ?[]const Segment {
    const success = if (ctx.exit_status) |status| status == 0 else true;

    const style = if (success)
        Style.parse("bold fg:green")
    else
        Style.parse("bold fg:red");

    const text = ctx.allocText("❯") catch return null;

    return ctx.addSegment(text, style) catch return null;
}
