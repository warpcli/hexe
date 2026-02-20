const std = @import("std");
const vaxis = @import("vaxis");
const render_bridge = @import("render_bridge.zig");
const render_buffer = @import("render_buffer.zig");
const render_types = @import("render_types.zig");

const CellBuffer = render_buffer.CellBuffer;
const CursorInfo = render_types.CursorInfo;

pub fn initVaxisForSize(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, width: u16, height: u16) !void {
    if (width == 0 or height == 0) return;
    vx.screen = try vaxis.Screen.init(allocator, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    vx.screen_last.deinit(allocator);
    vx.screen_last = try vaxis.AllocatingScreen.init(allocator, width, height);
}

pub fn resizeVaxisForSize(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, width: u16, height: u16) !void {
    vx.screen.deinit(allocator);
    vx.screen = try vaxis.Screen.init(allocator, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    vx.screen_last.deinit(allocator);
    vx.screen_last = try vaxis.AllocatingScreen.init(allocator, width, height);
}

pub fn copyBufferToVaxisScreen(next: *const CellBuffer, vx: *vaxis.Vaxis, arena: std.mem.Allocator) void {
    const width = next.width;
    const height = next.height;

    for (0..height) |yi| {
        const y: u16 = @intCast(yi);
        for (0..width) |xi| {
            const x: u16 = @intCast(xi);
            const cell = next.getConst(x, y);
            const vx_cell = render_bridge.cellToVaxis(cell, arena);
            vx.screen.writeCell(x, y, vx_cell);
        }
    }
}

pub fn renderFrame(vx: *vaxis.Vaxis, stdout: std.fs.File, cursor: CursorInfo, force_full: bool) !void {
    vx.screen.cursor_vis = cursor.visible;
    if (cursor.visible) {
        vx.screen.cursor = .{ .col = cursor.x, .row = cursor.y };
        vx.screen.cursor_shape = render_bridge.mapCursorShape(cursor.style);
    }

    if (force_full) {
        vx.refresh = true;
    }

    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writer(&write_buf);
    try vx.render(&writer.interface);
    writer.interface.flush() catch {};

    vx.refresh = false;
}
