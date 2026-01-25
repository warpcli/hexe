const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

// Persistent state for tracking network bytes between calls
var last_rx_bytes: u64 = 0;
var last_tx_bytes: u64 = 0;
var last_time_ns: i128 = 0;
var initialized: bool = false;

/// Netspeed segment - displays cumulative network upload/download speed across all interfaces
/// Format: ▲468K | ▼130K
pub fn render(ctx: *Context) ?[]const Segment {
    // Read total bytes from all interfaces
    const rx_bytes = getTotalBytes("/statistics/rx_bytes") orelse return null;
    const tx_bytes = getTotalBytes("/statistics/tx_bytes") orelse return null;

    const now_ns = std.time.nanoTimestamp();

    // Calculate speed if we have previous data
    var rx_speed: u64 = 0;
    var tx_speed: u64 = 0;

    if (initialized) {
        const elapsed_ns: u64 = @intCast(now_ns - last_time_ns);
        if (elapsed_ns > 0) {
            const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            if (rx_bytes >= last_rx_bytes) {
                rx_speed = @intFromFloat(@as(f64, @floatFromInt(rx_bytes - last_rx_bytes)) / elapsed_sec);
            }
            if (tx_bytes >= last_tx_bytes) {
                tx_speed = @intFromFloat(@as(f64, @floatFromInt(tx_bytes - last_tx_bytes)) / elapsed_sec);
            }
        }
    }

    // Update cached values
    last_rx_bytes = rx_bytes;
    last_tx_bytes = tx_bytes;
    last_time_ns = now_ns;
    initialized = true;

    // Format the output (shows 0K on first render)
    const tx_str = formatBytes(ctx, tx_speed) orelse return null;
    const rx_str = formatBytes(ctx, rx_speed) orelse return null;

    const text = ctx.allocFmt("▲{s} | ▼{s}", .{ tx_str, rx_str }) catch return null;

    return ctx.addSegment(text, Style{}) catch return null;
}

/// Sum up bytes from all network interfaces
fn getTotalBytes(suffix: []const u8) ?u64 {
    var total: u64 = 0;

    // Open /sys/class/net directory with iteration permissions
    var net_dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch return null;
    defer net_dir.close();

    // Iterate over all interfaces
    var iter = net_dir.iterate();
    while (iter.next() catch null) |entry| {
        // Skip . and ..
        if (entry.name[0] == '.') continue;

        // Skip loopback
        if (std.mem.eql(u8, entry.name, "lo")) continue;

        // Read bytes for this interface (even if entry.kind is unknown/symlink)
        if (readInterfaceBytes(entry.name, suffix)) |bytes| {
            total += bytes;
        }
    }

    return total;
}

/// Read bytes from a single interface's statistics file
fn readInterfaceBytes(iface: []const u8, suffix: []const u8) ?u64 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}{s}", .{ iface, suffix }) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [32]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = std.mem.trim(u8, buf[0..len], " \t\n");

    return std.fmt.parseInt(u64, str, 10) catch null;
}

fn formatBytes(ctx: *Context, bytes: u64) ?[]const u8 {
    if (bytes >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        if (mb >= 100.0) {
            return ctx.allocFmt("{d:>3.0}M", .{mb}) catch return null;
        } else if (mb >= 10.0) {
            return ctx.allocFmt("{d:>4.1}M", .{mb}) catch return null;
        } else {
            return ctx.allocFmt("{d:>4.2}M", .{mb}) catch return null;
        }
    } else {
        const kb = bytes / 1024;
        // Fixed 3-digit width for KB values
        return ctx.allocFmt("{d:>3}K", .{kb}) catch return null;
    }
}
