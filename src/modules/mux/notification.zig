const std = @import("std");
const pop = @import("pop");
const core = @import("core");
const vaxis = @import("vaxis");
const Renderer = @import("render_core.zig").Renderer;
const Color = core.style.Color;
const vaxis_cell = @import("vaxis_cell.zig");
const text_width = @import("text_width.zig");
const vaxis_surface = @import("vaxis_surface.zig");
const vaxis_draw = @import("vaxis_draw.zig");

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

    const clipped = text_width.clipTextToWidth(notif.message, max_msg_width);
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
            vaxis_draw.putChar(renderer, x + xi, y + yi, ' ', toRenderColor(style.fg), toRenderColor(style.bg), false);
        }
    }

    const text_y = y + style.padding_y;
    const text_x = x + style.padding_x;
    renderTextWithVaxis(renderer, text_x, text_y, clipped, style);
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

    const win = vaxis_surface.pooledWindow(std.heap.page_allocator, width, 1) catch return;

    const seg = vaxis.Segment{ .text = text, .style = toVaxisStyle(style) };
    const res = win.print(&.{seg}, .{ .wrap = .none, .commit = true });
    const end_col = @min(res.col, win.width);

    if (end_col > 0) {
        const clipped = win.child(.{ .width = end_col, .height = 1 });
        vaxis_surface.blitWindow(renderer, clipped, start_x, y);
    }
}

fn toRenderColor(c: pop.notification.Color) Color {
    return switch (c) {
        .none => .none,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}
