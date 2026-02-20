const pop = @import("pop");
const render = @import("render.zig");

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

    const max_msg_len = bounds_width -| style.padding_x * 2;
    const msg_len: u16 = @intCast(@min(notif.message.len, max_msg_len));
    if (msg_len == 0) return;

    const box_width = msg_len + style.padding_x * 2;
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
    for (0..msg_len) |i| {
        renderer.setCell(text_x + @as(u16, @intCast(i)), text_y, .{
            .char = notif.message[i],
            .fg = toRenderColor(style.fg),
            .bg = toRenderColor(style.bg),
            .bold = style.bold,
        });
    }
}

fn toRenderColor(c: pop.notification.Color) render.Color {
    return switch (c) {
        .none => .none,
        .palette => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}
