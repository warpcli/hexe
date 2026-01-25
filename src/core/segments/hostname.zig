const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Hostname segment - displays hostname
/// Format:  hostname
pub fn render(ctx: *Context) ?[]const Segment {
    // Try to get hostname from /etc/hostname first
    const hostname = getHostname() orelse return null;

    const text = ctx.allocFmt(" {s}", .{hostname}) catch return null;

    return ctx.addSegment(text, Style.parse("fg:blue")) catch return null;
}

fn getHostname() ?[]const u8 {
    // Try environment variable first
    if (std.posix.getenv("HOSTNAME")) |h| {
        return h;
    }

    // Try reading /etc/hostname
    const file = std.fs.openFileAbsolute("/etc/hostname", .{}) catch return null;
    defer file.close();

    var buf: [256]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const content = std.mem.trim(u8, buf[0..len], " \t\n\r");

    if (content.len == 0) return null;

    // Return static slice (hostname doesn't change during runtime)
    return content;
}
