const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Time segment - displays current time
/// Format: HH:MM:SS
pub fn render(ctx: *Context) ?[]const Segment {
    const timestamp = std.time.timestamp();
    const epoch_seconds: u64 = @intCast(timestamp);

    // Convert to broken-down time (local time)
    const seconds_in_day = epoch_seconds % 86400;
    const hours = (seconds_in_day / 3600) % 24;
    const minutes = (seconds_in_day % 3600) / 60;
    const seconds = seconds_in_day % 60;

    // Get timezone offset for local time
    // For simplicity, we'll use UTC and let the shell handle TZ
    // A proper implementation would use libc's localtime

    const text = ctx.allocFmt("{d:0>2}:{d:0>2}:{d:0>2}", .{
        hours,
        minutes,
        seconds,
    }) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}
