const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

// Persistent state for CPU calculation (use struct to prevent optimization issues)
const CpuState = struct {
    idle: u64 = 0,
    total: u64 = 0,
    initialized: bool = false,
    last_percent: u64 = 0,
};
var state: CpuState = .{};

/// CPU segment - displays CPU usage percentage
/// Format: 94
pub fn render(ctx: *Context) ?[]const Segment {
    // Read /proc/stat
    const file = std.fs.openFileAbsolute("/proc/stat", .{}) catch {
        // Return last known value if can't read
        const text = ctx.allocFmt("{d:>2}", .{state.last_percent}) catch return null;
        return ctx.addSegment(text, Style{}) catch return null;
    };
    defer file.close();

    var buf: [512]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const str = buf[0..len];

    // Parse first line (cpu aggregate)
    var lines = std.mem.tokenizeScalar(u8, str, '\n');
    const cpu_line = lines.next() orelse return null;

    if (!std.mem.startsWith(u8, cpu_line, "cpu ")) return null;

    // Parse: cpu user nice system idle iowait irq softirq steal guest guest_nice
    var iter = std.mem.tokenizeAny(u8, cpu_line, " ");
    _ = iter.next(); // skip "cpu"

    var values: [10]u64 = undefined;
    var i: usize = 0;
    while (iter.next()) |val| {
        if (i >= 10) break;
        values[i] = std.fmt.parseInt(u64, val, 10) catch 0;
        i += 1;
    }

    if (i < 4) return null;

    // Calculate totals
    // user, nice, system, idle, iowait, irq, softirq, steal
    var total: u64 = 0;
    for (values[0..@min(i, 8)]) |v| {
        total += v;
    }

    const idle = values[3]; // idle is 4th field

    // Calculate percentage
    var cpu_percent: u64 = state.last_percent;
    if (state.initialized and total > state.total) {
        const total_diff = total - state.total;
        const idle_diff = if (idle >= state.idle) idle - state.idle else 0;
        if (total_diff > 0) {
            const active = if (total_diff > idle_diff) total_diff - idle_diff else 0;
            cpu_percent = (active * 100) / total_diff;
        }
    }

    // Update state
    state.idle = idle;
    state.total = total;
    state.initialized = true;
    state.last_percent = cpu_percent;

    // Fixed 2-digit width (space-padded for 0-9)
    const text = ctx.allocFmt("{d:>2}", .{cpu_percent}) catch return null;
    return ctx.addSegment(text, Style{}) catch return null;
}
