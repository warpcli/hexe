const std = @import("std");
const render = @import("render.zig");
const Color = render.Color;
const RGB = Color.RGB;

/// Saved cell colors for restoration after pulse
pub const SavedCell = struct {
    fg: Color,
    bg: Color,
};

/// Standard 256-color palette (0-255) to RGB conversion
/// Based on standard terminal color palette
pub fn paletteToRgb(palette: u8) RGB {
    // Standard 16 colors (0-15)
    if (palette < 16) {
        return switch (palette) {
            0 => RGB{ .r = 0, .g = 0, .b = 0 }, // black
            1 => RGB{ .r = 128, .g = 0, .b = 0 }, // red
            2 => RGB{ .r = 0, .g = 128, .b = 0 }, // green
            3 => RGB{ .r = 128, .g = 128, .b = 0 }, // yellow
            4 => RGB{ .r = 0, .g = 0, .b = 128 }, // blue
            5 => RGB{ .r = 128, .g = 0, .b = 128 }, // magenta
            6 => RGB{ .r = 0, .g = 128, .b = 128 }, // cyan
            7 => RGB{ .r = 192, .g = 192, .b = 192 }, // white
            8 => RGB{ .r = 128, .g = 128, .b = 128 }, // bright black
            9 => RGB{ .r = 255, .g = 0, .b = 0 }, // bright red
            10 => RGB{ .r = 0, .g = 255, .b = 0 }, // bright green
            11 => RGB{ .r = 255, .g = 255, .b = 0 }, // bright yellow
            12 => RGB{ .r = 0, .g = 0, .b = 255 }, // bright blue
            13 => RGB{ .r = 255, .g = 0, .b = 255 }, // bright magenta
            14 => RGB{ .r = 0, .g = 255, .b = 255 }, // bright cyan
            15 => RGB{ .r = 255, .g = 255, .b = 255 }, // bright white
            else => unreachable,
        };
    }

    // 216-color cube (16-231): 6x6x6 RGB cube
    if (palette >= 16 and palette < 232) {
        const idx = palette - 16;
        const r = (idx / 36) % 6;
        const g = (idx / 6) % 6;
        const b = idx % 6;
        const r8 = if (r == 0) 0 else @as(u8, @intCast(55 + r * 40));
        const g8 = if (g == 0) 0 else @as(u8, @intCast(55 + g * 40));
        const b8 = if (b == 0) 0 else @as(u8, @intCast(55 + b * 40));
        return RGB{ .r = r8, .g = g8, .b = b8 };
    }

    // Grayscale ramp (232-255): 24 shades of gray
    if (palette >= 232) {
        const gray = 8 + (palette - 232) * 10;
        return RGB{ .r = gray, .g = gray, .b = gray };
    }

    unreachable;
}

/// Brighten an RGB color by a factor (1.0 = no change, 2.0 = much brighter)
pub fn brightenRgb(rgb: RGB, factor: f32) RGB {
    const r = @min(255, @as(u8, @intFromFloat(@as(f32, @floatFromInt(rgb.r)) * factor)));
    const g = @min(255, @as(u8, @intFromFloat(@as(f32, @floatFromInt(rgb.g)) * factor)));
    const b = @min(255, @as(u8, @intFromFloat(@as(f32, @floatFromInt(rgb.b)) * factor)));
    return RGB{ .r = r, .g = g, .b = b };
}

/// Darken an RGB color by a factor (1.0 = no change, 0.5 = half brightness)
pub fn darkenRgb(rgb: RGB, factor: f32) RGB {
    const r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rgb.r)) * factor));
    const g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rgb.g)) * factor));
    const b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(rgb.b)) * factor));
    return RGB{ .r = r, .g = g, .b = b };
}

/// Convert a Color to RGB (converting palette if needed)
pub fn colorToRgb(color: Color) RGB {
    return switch (color) {
        .none => RGB{ .r = 0, .g = 0, .b = 0 }, // default to black
        .palette => |p| paletteToRgb(p),
        .rgb => |rgb| rgb,
    };
}

/// Brighten a Color (converting to RGB if needed)
pub fn brightenColor(color: Color, factor: f32) Color {
    const rgb = colorToRgb(color);
    return .{ .rgb = brightenRgb(rgb, factor) };
}

/// Darken a Color (converting to RGB if needed)
pub fn darkenColor(color: Color, factor: f32) Color {
    const rgb = colorToRgb(color);
    return .{ .rgb = darkenRgb(rgb, factor) };
}
