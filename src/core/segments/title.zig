const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Title segment - shows the current focused pane/float title when available.
pub fn render(ctx: *Context) ?[]const Segment {
    const title = ctx.title orelse return null;
    if (title.len == 0) return null;

    const text = ctx.allocText(title) catch return null;
    return ctx.addSegment(text, Style{}) catch return null;
}
