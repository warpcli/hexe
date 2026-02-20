const std = @import("std");
const vaxis = @import("vaxis");
const render = @import("render.zig");

pub fn toVaxisColor(c: anytype) vaxis.Color {
    return switch (c) {
        .none => .default,
        .palette => |idx| .{ .index = idx },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}

pub fn toRenderColor(col: vaxis.Color) render.Color {
    return switch (col) {
        .default => .none,
        .index => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } },
    };
}

pub fn toRenderCell(cell: vaxis.Cell) render.Cell {
    var out: render.Cell = .{
        .char = ' ',
        .fg = toRenderColor(cell.style.fg),
        .bg = toRenderColor(cell.style.bg),
        .bold = cell.style.bold,
        .italic = cell.style.italic,
        .faint = cell.style.dim,
        .strikethrough = cell.style.strikethrough,
        .inverse = cell.style.reverse,
    };
    out.underline = switch (cell.style.ul_style) {
        .off => .none,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };

    if (cell.char.width == 0 or cell.char.grapheme.len == 0) {
        out.char = 0;
        out.is_wide_spacer = true;
        return out;
    }

    out.char = std.unicode.utf8Decode(cell.char.grapheme) catch ' ';
    out.is_wide_char = cell.char.width == 2;
    return out;
}
