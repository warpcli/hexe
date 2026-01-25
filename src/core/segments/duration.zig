const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Duration segment - displays command execution time if above threshold
/// Format: took 2.5s, took 1m 30s, took 1h 2m
pub fn render(ctx: *Context) ?[]const Segment {
    const duration_ms = ctx.cmd_duration_ms orelse return null;

    // Only show if above threshold (2 seconds)
    const threshold_ms: u64 = 2000;
    if (duration_ms < threshold_ms) return null;

    const formatted = formatDuration(ctx, duration_ms) orelse return null;
    const text = ctx.allocFmt("took {s}", .{formatted}) catch return null;

    return ctx.addSegment(text, Style.parse("fg:yellow")) catch return null;
}

fn formatDuration(ctx: *Context, ms: u64) ?[]const u8 {
    const seconds = ms / 1000;
    const minutes = seconds / 60;
    const hours = minutes / 60;

    if (hours > 0) {
        const remaining_mins = minutes % 60;
        return ctx.allocFmt("{d}h {d}m", .{ hours, remaining_mins }) catch return null;
    } else if (minutes > 0) {
        const remaining_secs = seconds % 60;
        return ctx.allocFmt("{d}m {d}s", .{ minutes, remaining_secs }) catch return null;
    } else if (seconds >= 10) {
        return ctx.allocFmt("{d}s", .{seconds}) catch return null;
    } else {
        // Show decimal for short durations
        const secs_f = @as(f64, @floatFromInt(ms)) / 1000.0;
        return ctx.allocFmt("{d:.1}s", .{secs_f}) catch return null;
    }
}
