const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Custom segment configuration
pub const CustomConfig = struct {
    command: []const u8,
    when: ?[]const u8 = null, // Optional condition command
    style: []const u8 = "",
    format: []const u8 = "$output", // How to format the output
};

/// Render a custom segment by running a shell command
pub fn renderCustom(ctx: *Context, config: CustomConfig) ?[]const Segment {
    // Check condition if specified
    if (config.when) |when_cmd| {
        if (!runCondition(when_cmd)) return null;
    }

    // Run the main command
    const output = runCommand(ctx, config.command) orelse return null;
    if (output.len == 0) return null;

    // Format the output
    const text = formatOutput(ctx, config.format, output) orelse return null;

    const style = if (config.style.len > 0)
        Style.parse(config.style)
    else
        Style{};

    return ctx.addSegment(text, style) catch return null;
}

/// Run a condition command, return true if exit code is 0
fn runCondition(cmd: []const u8) bool {
    var child = std.process.Child.init(.{
        .argv = &.{ "/bin/sh", "-c", cmd },
    }, std.heap.page_allocator);

    child.spawn() catch return false;
    const result = child.wait() catch return false;

    return result.Exited == 0;
}

/// Run a command and capture its stdout
fn runCommand(ctx: *Context, cmd: []const u8) ?[]const u8 {
    _ = ctx;

    var child = std.process.Child.init(.{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdout_behavior = .Pipe,
        .stderr_behavior = .Ignore,
    }, std.heap.page_allocator);

    child.spawn() catch return null;

    // Read stdout
    var stdout_buf: [1024]u8 = undefined;
    const stdout = child.stdout orelse return null;
    const len = stdout.read(&stdout_buf) catch return null;

    _ = child.wait() catch return null;

    if (len == 0) return null;

    // Trim whitespace
    return std.mem.trim(u8, stdout_buf[0..len], " \t\n\r");
}

/// Format the output with the format string
fn formatOutput(ctx: *Context, format: []const u8, output: []const u8) ?[]const u8 {
    // Simple replacement of $output
    if (std.mem.indexOf(u8, format, "$output")) |idx| {
        const before = format[0..idx];
        const after = format[idx + 7 ..];
        return ctx.allocFmt("{s}{s}{s}", .{ before, output, after }) catch return null;
    }

    // No placeholder, just return the output
    return ctx.allocText(output) catch return null;
}

/// Registry entry for looking up custom segments by name
/// This would be populated from config at runtime
pub var custom_registry: std.StringHashMap(CustomConfig) = undefined;
var registry_initialized = false;

pub fn initRegistry(allocator: std.mem.Allocator) void {
    if (!registry_initialized) {
        custom_registry = std.StringHashMap(CustomConfig).init(allocator);
        registry_initialized = true;
    }
}

pub fn registerCustom(name: []const u8, config: CustomConfig) !void {
    try custom_registry.put(name, config);
}

pub fn getCustom(name: []const u8) ?CustomConfig {
    return custom_registry.get(name);
}
