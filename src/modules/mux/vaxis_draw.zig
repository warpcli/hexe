const std = @import("std");
const vaxis = @import("vaxis");
const core = @import("core");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const vaxis_cell = @import("vaxis_cell.zig");

pub fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: ?Color, bg: ?Color, bold: bool) void {
    var buf: [4]u8 = undefined;
    const grapheme: []const u8 = if (cp < 128)
        buf[0..blk: {
            buf[0] = @intCast(cp);
            break :blk 1;
        }]
    else blk: {
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        break :blk buf[0..n];
    };

    var style: vaxis.Style = .{ .bold = bold };
    if (fg) |c| style.fg = vaxis_cell.toVaxisColor(c);
    if (bg) |c| style.bg = vaxis_cell.toVaxisColor(c);

    renderer.setVaxisCell(x, y, .{
        .char = .{ .grapheme = grapheme, .width = 1 },
        .style = style,
    });
}
