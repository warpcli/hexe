const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

const c = @cImport({
    @cInclude("time.h");
});

/// Time segment - displays current time in local timezone
/// Format: HH:MM:SS
pub fn render(ctx: *Context) ?[]const Segment {
    const timestamp = std.time.timestamp();

    // Use libc's localtime to get proper local time with timezone
    var time_val: c.time_t = @intCast(timestamp);
    const local = c.localtime(&time_val);
    if (local == null) return null;

    const hours: u64 = @intCast(local.*.tm_hour);
    const minutes: u64 = @intCast(local.*.tm_min);
    const seconds: u64 = @intCast(local.*.tm_sec);

    const text = ctx.allocFmt("{d:0>2}:{d:0>2}:{d:0>2}", .{
        hours,
        minutes,
        seconds,
    }) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}
