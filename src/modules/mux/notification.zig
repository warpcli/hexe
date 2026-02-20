const std = @import("std");
const pop = @import("pop");
const vaxis = @import("vaxis");
const render = @import("render.zig");
const vaxis_cell = @import("vaxis_cell.zig");

const Renderer = render.Renderer;

pub fn renderFull(self: *pop.notification.NotificationManager, renderer: *Renderer, screen_width: u16, screen_height: u16) void {
    renderInBounds(self, renderer, 0, 0, screen_width, screen_height, true);
}

pub fn renderInBounds(
    self: *pop.notification.NotificationManager,
    renderer: *Renderer,
    bounds_x: u16,
    bounds_y: u16,
    bounds_width: u16,
    bounds_height: u16,
    is_mux_realm: bool,
) void {
    const notif = self.current orelse return;
    const style = notif.style;

    const max_msg_width = bounds_width -| style.padding_x * 2;
    if (max_msg_width == 0) return;

    const clipped = clipTextToWidth(notif.message, max_msg_width);
    const msg_width = vaxis.gwidth.gwidth(clipped, .unicode);
    if (msg_width == 0) return;

    const box_width = msg_width + style.padding_x * 2;
    const box_height: u16 = 1 + style.padding_y * 2;

    const x: u16 = switch (style.alignment) {
        .left => bounds_x,
        .center => bounds_x + (bounds_width -| box_width) / 2,
        .right => bounds_x + bounds_width -| box_width,
    };

    const y: u16 = if (is_mux_realm)
        bounds_y + style.offset
    else
        bounds_y + bounds_height -| box_height -| style.offset;

    var yi: u16 = 0;
    while (yi < box_height) : (yi += 1) {
        var xi: u16 = 0;
        while (xi < box_width) : (xi += 1) {
            renderer.setCell(x + xi, y + yi, .{
                .char = ' ',
                .fg = toRenderColor(style.fg),
                .bg = toRenderColor(style.bg),
            });
        }
    }

    const text_y = y + style.padding_y;
    const text_x = x + style.padding_x;
    renderTextWithVaxis(renderer, text_x, text_y, clipped, style);
}

fn clipTextToWidth(text: []const u8, max_width: u16) []const u8 {
    if (text.len == 0 or max_width == 0) return "";

    var used: u16 = 0;
    var end: usize = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        const w = vaxis.gwidth.gwidth(bytes, .unicode);
        if (w == 0) {
            end = g.start + g.len;
            continue;
        }
        if (used + w > max_width) break;
        used += w;
        end = g.start + g.len;
    }
    return text[0..end];
}

fn toVaxisStyle(style: pop.notification.Style) vaxis.Style {
    return .{
        .fg = vaxis_cell.toVaxisColor(style.fg),
        .bg = vaxis_cell.toVaxisColor(style.bg),
        .bold = style.bold,
    };
}

fn renderTextWithVaxis(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: pop.notification.Style) void {
    const width = vaxis.gwidth.gwidth(text, .unicode);
    if (width == 0) return;

    var screen = vaxis.Screen.init(std.heap.page_allocator, .{ .cols = width, .rows = 1, .x_pixel = 0, .y_pixel = 0 }) catch return;
    defer screen.deinit(std.heap.page_allocator);
    screen.width_method = .unicode;

    const win: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = 1,
        .screen = &screen,
    };

    const seg = vaxis.Segment{ .text = text, .style = toVaxisStyle(style) };
    const res = win.print(&.{seg}, .{ .wrap = .none, .commit = true });
    const end_col = @min(res.col, screen.width);

    var x: u16 = 0;
    while (x < end_col) : (x += 1) {
        const vx_cell = screen.readCell(x, 0) orelse continue;
        renderer.setCell(start_x + x, y, vaxis_cell.toRenderCell(vx_cell));
    }
}

fn toRenderColor(c: pop.notification.Color) render.Color {
    return switch (c) {
        .none => .none,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}
