const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

// Cache last value for error recovery
var last_percent: u64 = 0;

/// Memory segment - displays memory usage percentage
/// Format: 67
pub fn render(ctx: *Context) ?[]const Segment {
    // Read /proc/meminfo - open fresh each time
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        const text = ctx.allocFmt("{d:>2}", .{last_percent}) catch return null;
        return ctx.addSegment(text, Style{}) catch return null;
    };
    defer file.close();

    var buf: [2048]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = buf[0..len];

    var mem_total: u64 = 0;
    var mem_available: u64 = 0;

    // Parse lines
    var lines = std.mem.tokenizeScalar(u8, str, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            mem_total = parseMemValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            mem_available = parseMemValue(line);
        }

        if (mem_total > 0 and mem_available > 0) break;
    }

    if (mem_total == 0) return null;

    // Calculate percentage used
    const mem_used = mem_total - mem_available;
    const mem_percent = (mem_used * 100) / mem_total;
    last_percent = mem_percent;

    // Fixed 2-digit width (space-padded for 0-9)
    const text = ctx.allocFmt("{d:>2}", .{mem_percent}) catch return null;
    return ctx.addSegment(text, Style{}) catch return null;
}

fn parseMemValue(line: []const u8) u64 {
    // Format: "MemTotal:       16384000 kB"
    var iter = std.mem.tokenizeAny(u8, line, " \t:");
    _ = iter.next(); // skip name
    const value_str = iter.next() orelse return 0;
    return std.fmt.parseInt(u64, value_str, 10) catch 0;
}
