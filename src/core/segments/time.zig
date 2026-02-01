const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

const c = @cImport({
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

var tz_initialized: bool = false;

/// Time segment - displays current time in local timezone
/// Format: HH:MM:SS
pub fn render(ctx: *Context) ?[]const Segment {
    // Ensure TZDIR is set for Nix/non-standard glibc environments
    if (!tz_initialized) {
        _ = c.setenv("TZDIR", "/usr/share/zoneinfo", 0); // Don't override if already set
        c.tzset();
        tz_initialized = true;
    }

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
