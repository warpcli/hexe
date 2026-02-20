const shp = @import("shp");
const render_types = @import("render_types.zig");

pub fn renderColorToShp(c: render_types.Color) shp.Color {
    return switch (c) {
        .none => .none,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

pub fn textStyle(fg: render_types.Color, bg: render_types.Color, bold: bool) shp.Style {
    return .{
        .fg = renderColorToShp(fg),
        .bg = renderColorToShp(bg),
        .bold = bold,
    };
}
