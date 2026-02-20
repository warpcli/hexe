const std = @import("std");
const vaxis = @import("vaxis");

/// Static ASCII lookup table for fast codepoint -> grapheme conversion.
const ascii_lut: [128]u8 = initAsciiLut();

fn initAsciiLut() [128]u8 {
    var table: [128]u8 = undefined;
    for (0..128) |i| table[i] = @intCast(i);
    return table;
}

/// Convert a render cell-like type to a vaxis cell.
/// Expects fields compatible with mux `render.Cell`.
pub fn cellToVaxis(cell: anytype, arena: std.mem.Allocator) vaxis.Cell {
    const grapheme: []const u8 = if (cell.is_wide_spacer)
        ""
    else if (cell.char == 0 or cell.char == ' ')
        " "
    else if (cell.char < 128)
        ascii_lut[@intCast(cell.char)..][0..1]
    else blk: {
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.char, &utf8_buf) catch break :blk " ";
        break :blk arena.dupe(u8, utf8_buf[0..len]) catch " ";
    };

    const char_width: u8 = if (cell.is_wide_spacer) 0 else if (cell.is_wide_char) 2 else 1;

    return .{
        .char = .{ .grapheme = grapheme, .width = char_width },
        .style = .{
            .fg = colorToVaxis(cell.fg),
            .bg = colorToVaxis(cell.bg),
            .bold = cell.bold,
            .dim = cell.faint,
            .italic = cell.italic,
            .reverse = cell.inverse,
            .strikethrough = cell.strikethrough,
            .ul_style = switch (cell.underline) {
                .none => .off,
                .single => .single,
                .double => .double,
                .curly => .curly,
                .dotted => .dotted,
                .dashed => .dashed,
            },
        },
    };
}

/// Convert a render color-like union to a vaxis color.
pub fn colorToVaxis(c: anytype) vaxis.Cell.Color {
    return switch (c) {
        .none => .default,
        .palette => |p| .{ .index = p },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}

/// Map DECSCUSR cursor style (0-6) to vaxis cursor shape.
pub fn mapCursorShape(style: u8) vaxis.Cell.CursorShape {
    return switch (style) {
        1 => .block_blink,
        2 => .block,
        3 => .underline_blink,
        4 => .underline,
        5 => .beam_blink,
        6 => .beam,
        else => .default,
    };
}
