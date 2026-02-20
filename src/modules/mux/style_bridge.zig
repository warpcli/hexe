const shp = @import("shp");
const render = @import("render.zig");

pub fn renderColorToShp(c: render.Color) shp.Color {
    return switch (c) {
        .none => .none,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

pub fn textStyle(fg: render.Color, bg: render.Color, bold: bool) shp.Style {
    return .{
        .fg = renderColorToShp(fg),
        .bg = renderColorToShp(bg),
        .bold = bold,
    };
}
