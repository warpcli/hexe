const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Uptime segment - displays system uptime
/// Format: up 4 days, 14 hours, 38 minutes
pub fn render(ctx: *Context) ?[]const Segment {
    // Read /proc/uptime
    const file = std.fs.openFileAbsolute("/proc/uptime", .{}) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = buf[0..len];

    // Parse first number (uptime in seconds)
    var iter = std.mem.tokenizeAny(u8, str, " \t\n");
    const uptime_str = iter.next() orelse return null;

    // Parse as float and convert to integer seconds
    const uptime_float = std.fmt.parseFloat(f64, uptime_str) catch return null;
    const uptime_secs: u64 = @intFromFloat(uptime_float);

    // Calculate components
    const days = uptime_secs / 86400;
    const hours = (uptime_secs % 86400) / 3600;
    const minutes = (uptime_secs % 3600) / 60;

    // Format output
    const text = if (days > 0)
        ctx.allocFmt("up {d} days, {d} hours, {d}", .{ days, hours, minutes }) catch return null
    else if (hours > 0)
        ctx.allocFmt("up {d} hours, {d} min", .{ hours, minutes }) catch return null
    else
        ctx.allocFmt("up {d} min", .{minutes}) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}
