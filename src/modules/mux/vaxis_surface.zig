const std = @import("std");
const vaxis = @import("vaxis");
const render = @import("render.zig");
const vaxis_cell = @import("vaxis_cell.zig");

pub const Renderer = render.Renderer;

pub fn initUnicodeScreen(allocator: std.mem.Allocator, cols: u16, rows: u16) !vaxis.Screen {
    var screen = try vaxis.Screen.init(allocator, .{
        .cols = cols,
        .rows = rows,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    screen.width_method = .unicode;
    return screen;
}

pub fn rootWindow(screen: *vaxis.Screen) vaxis.Window {
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = screen,
    };
}

pub fn blitScreen(renderer: *Renderer, screen: *const vaxis.Screen, dst_x: u16, dst_y: u16) void {
    for (0..screen.height) |ry| {
        for (0..screen.width) |rx| {
            const sx: u16 = @intCast(rx);
            const sy: u16 = @intCast(ry);
            const vx_cell = screen.readCell(sx, sy) orelse continue;
            renderer.setCell(dst_x + sx, dst_y + sy, vaxis_cell.toRenderCell(vx_cell));
        }
    }
}

pub fn blitTouched(
    renderer: *Renderer,
    screen: *const vaxis.Screen,
    touched: []const bool,
    stride: u16,
    dst_x: u16,
    dst_y: u16,
) void {
    for (0..screen.height) |ry| {
        for (0..screen.width) |rx| {
            const idx = ry * @as(usize, stride) + rx;
            if (idx >= touched.len or !touched[idx]) continue;
            const sx: u16 = @intCast(rx);
            const sy: u16 = @intCast(ry);
            const vx_cell = screen.readCell(sx, sy) orelse continue;
            renderer.setCell(dst_x + sx, dst_y + sy, vaxis_cell.toRenderCell(vx_cell));
        }
    }
}
