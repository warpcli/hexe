const std = @import("std");
const vaxis = @import("vaxis");
const render = @import("render.zig");
const vaxis_cell = @import("vaxis_cell.zig");

pub const Renderer = render.Renderer;

threadlocal var pooled_screen: ?vaxis.Screen = null;
threadlocal var pooled_cols: u16 = 0;
threadlocal var pooled_rows: u16 = 0;

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

pub fn deinitThreadlocals(allocator: std.mem.Allocator) void {
    if (pooled_screen) |*screen| {
        screen.deinit(allocator);
        pooled_screen = null;
        pooled_cols = 0;
        pooled_rows = 0;
    }
}

pub fn pooledWindow(allocator: std.mem.Allocator, cols: u16, rows: u16) !vaxis.Window {
    if (cols == 0 or rows == 0) return error.InvalidDimensions;

    if (pooled_screen == null or pooled_cols < cols or pooled_rows < rows) {
        const new_cols = @max(cols, pooled_cols);
        const new_rows = @max(rows, pooled_rows);
        if (pooled_screen) |*old| {
            old.deinit(allocator);
            pooled_screen = null;
        }
        pooled_screen = try initUnicodeScreen(allocator, new_cols, new_rows);
        pooled_cols = new_cols;
        pooled_rows = new_rows;
    }

    const root = rootWindow(&pooled_screen.?);
    return root.child(.{ .width = cols, .height = rows });
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

pub fn blitWindow(renderer: *Renderer, win: vaxis.Window, dst_x: u16, dst_y: u16) void {
    for (0..win.height) |ry| {
        for (0..win.width) |rx| {
            const sx: u16 = @intCast(rx);
            const sy: u16 = @intCast(ry);
            const vx_cell = win.readCell(sx, sy) orelse continue;
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
