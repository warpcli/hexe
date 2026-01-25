const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Battery segment - displays battery percentage
/// Format: 85%
/// Returns null if no battery is present
pub fn render(ctx: *Context) ?[]const Segment {
    // Try common battery paths
    const battery_paths = [_][]const u8{
        "/sys/class/power_supply/BAT0",
        "/sys/class/power_supply/BAT1",
        "/sys/class/power_supply/battery",
    };

    for (battery_paths) |bat_path| {
        if (readBattery(ctx, bat_path)) |segs| {
            return segs;
        }
    }

    return null;
}

fn readBattery(ctx: *Context, bat_path: []const u8) ?[]const Segment {
    var path_buf: [128]u8 = undefined;

    // Read capacity
    const capacity_path = std.fmt.bufPrint(&path_buf, "{s}/capacity", .{bat_path}) catch return null;
    const capacity = readFileInt(capacity_path) orelse return null;

    // Read status (optional, for styling)
    var status_buf: [64]u8 = undefined;
    const status_path = std.fmt.bufPrint(&status_buf, "{s}/status", .{bat_path}) catch return null;
    const status = readFileStr(status_path);

    // Determine style based on status
    var style = Style{};
    if (status) |s| {
        if (std.mem.eql(u8, s, "Discharging")) {
            // Red when discharging
            style = Style.parse("fg:red");
        }
    }

    // Fixed 3-digit width for percentage (space-padded)
    const text = ctx.allocFmt("{d:>3}%", .{capacity}) catch return null;
    return ctx.addSegment(text, style) catch return null;
}

fn readFileInt(path: []const u8) ?u64 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [32]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = std.mem.trim(u8, buf[0..len], " \t\n");

    return std.fmt.parseInt(u64, str, 10) catch null;
}

fn readFileStr(path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [64]u8 = undefined;
    const len = file.read(&buf) catch return null;

    // Return trimmed content (static buffer, only valid for immediate use)
    const trimmed = std.mem.trim(u8, buf[0..len], " \t\n");
    if (trimmed.len == 0) return null;

    // Copy to a position in buffer that won't be reused
    return trimmed;
}
