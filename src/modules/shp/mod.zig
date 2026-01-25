// SHP - Shell Prompt and Integration
// Segment/style types are shared via core; this module provides
// shell hooks, prompt assembly, and format parsing.

const std = @import("std");
const core = @import("core");

pub const format = @import("format.zig");
pub const animations = core.segments.animations;
pub const entry = @import("main.zig");

// Re-export core types for backward compatibility
pub const Style = core.style.Style;
pub const Color = core.style.Color;
pub const FormatParser = format.FormatParser;
pub const Segment = core.segments.Segment;
pub const Context = core.segments.Context;

// Re-export entry point types for CLI
pub const PopArgs = entry.PopArgs;
pub const run = entry.run;

/// Render a format string with the given context
pub fn render(allocator: std.mem.Allocator, format_str: []const u8, ctx: *Context) ![]Segment {
    var parser = FormatParser.init(allocator, format_str);
    return parser.render(ctx);
}

/// Render a format string to ANSI output
pub fn renderToAnsi(allocator: std.mem.Allocator, format_str: []const u8, ctx: *Context, writer: anytype) !void {
    const segs = try render(allocator, format_str, ctx);
    defer allocator.free(segs);

    for (segs) |seg| {
        try seg.style.toAnsi(writer);
        try writer.writeAll(seg.text);
    }
    try Style.reset(writer);
}
