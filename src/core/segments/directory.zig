const std = @import("std");
const Segment = @import("context.zig").Segment;
const Context = @import("context.zig").Context;
const Style = @import("../style.zig").Style;

/// Directory segment - displays current working directory with truncation
/// Format:  ~/D/c/bloxs (fish-style) or  …/code/bloxs (truncated)
pub fn render(ctx: *Context) ?[]const Segment {
    const cwd = if (ctx.cwd.len > 0) ctx.cwd else std.posix.getenv("PWD") orelse return null;
    const home = ctx.home orelse std.posix.getenv("HOME");

    // Replace home with ~
    var path: []const u8 = cwd;
    var starts_with_home = false;
    if (home) |h| {
        if (std.mem.startsWith(u8, cwd, h)) {
            path = cwd[h.len..];
            starts_with_home = true;
        }
    }

    // Fish-style truncation: ~/D/c/bloxs
    const truncated = fishStyleTruncate(ctx, path, starts_with_home) orelse return null;

    const text = ctx.allocFmt(" {s}", .{truncated}) catch return null;

    return ctx.addSegment(text, Style.parse("bold fg:cyan")) catch return null;
}

/// Fish-style path truncation: keep first letter of each component except last
fn fishStyleTruncate(ctx: *Context, path: []const u8, starts_with_home: bool) ?[]const u8 {
    if (path.len == 0) {
        if (starts_with_home) {
            return "~";
        }
        return "/";
    }

    // Count components and build truncated path
    var result_buf: [512]u8 = undefined;
    var result_len: usize = 0;

    // Add ~ prefix if applicable
    if (starts_with_home) {
        result_buf[0] = '~';
        result_len = 1;
    }

    var iter = std.mem.tokenizeScalar(u8, path, '/');
    var components: [32][]const u8 = undefined;
    var count: usize = 0;

    while (iter.next()) |comp| {
        if (count < 32) {
            components[count] = comp;
            count += 1;
        }
    }

    if (count == 0) {
        if (starts_with_home) {
            return "~";
        }
        return "/";
    }

    // Truncate all but last component
    for (components[0..count], 0..) |comp, i| {
        // Add separator
        if (result_len < result_buf.len) {
            result_buf[result_len] = '/';
            result_len += 1;
        }

        if (i < count - 1) {
            // Truncate to first char (or first char after . for hidden)
            if (comp.len > 0) {
                if (comp[0] == '.' and comp.len > 1) {
                    // Hidden dir: keep .x
                    if (result_len + 2 <= result_buf.len) {
                        result_buf[result_len] = '.';
                        result_buf[result_len + 1] = comp[1];
                        result_len += 2;
                    }
                } else {
                    // Normal dir: keep first char
                    if (result_len < result_buf.len) {
                        result_buf[result_len] = comp[0];
                        result_len += 1;
                    }
                }
            }
        } else {
            // Last component: keep full name
            const to_copy = @min(comp.len, result_buf.len - result_len);
            @memcpy(result_buf[result_len..][0..to_copy], comp[0..to_copy]);
            result_len += to_copy;
        }
    }

    return ctx.allocText(result_buf[0..result_len]) catch return null;
}
