const std = @import("std");

const core = @import("core");

const Pane = @import("pane.zig").Pane;
const render = @import("render.zig");
const Renderer = render.Renderer;
const statusbar = @import("statusbar.zig");

pub const TitleRect = struct {
    x: u16,
    y: u16,
    w: u16,
};

pub fn getTitleRect(pane: *const Pane) ?TitleRect {
    const title = pane.float_title orelse return null;
    if (title.len == 0) return null;

    const style = pane.float_style orelse return null;
    const module = style.module orelse return null;
    const pos = style.position orelse return null;

    const outer_x = pane.border_x;
    const outer_y = pane.border_y;
    const outer_w = pane.border_w;
    const outer_h = pane.border_h;
    if (outer_w < 3 or outer_h < 3) return null;

    const segments = statusbar.renderSegmentOutput(&module, title);
    const total_len: u16 = @intCast(@min(@as(usize, outer_w -| 2), segments.total_len));
    if (total_len == 0) return null;

    var draw_x: u16 = undefined;
    var draw_y: u16 = undefined;

    switch (pos) {
        .topleft => {
            draw_x = outer_x + 2;
            draw_y = outer_y;
        },
        .topcenter => {
            draw_x = outer_x + @as(u16, @intCast((outer_w -| total_len) / 2));
            draw_y = outer_y;
        },
        .topright => {
            draw_x = outer_x + outer_w -| 2 -| total_len;
            draw_y = outer_y;
        },
        .bottomleft => {
            draw_x = outer_x + 2;
            draw_y = outer_y + outer_h - 1;
        },
        .bottomcenter => {
            draw_x = outer_x + @as(u16, @intCast((outer_w -| total_len) / 2));
            draw_y = outer_y + outer_h - 1;
        },
        .bottomright => {
            draw_x = outer_x + outer_w -| 2 -| total_len;
            draw_y = outer_y + outer_h - 1;
        },
    }

    return .{ .x = draw_x, .y = draw_y, .w = total_len };
}

pub fn hitTestTitle(pane: *const Pane, x: u16, y: u16) bool {
    const r = getTitleRect(pane) orelse return false;
    if (y != r.y) return false;
    return x >= r.x and x < r.x + r.w;
}

/// Draw an in-place title editor overlay.
///
/// This draws a 1-line highlighted box at the same border position as the float
/// title widget. The box width follows the current buffer length.
pub fn drawTitleEditor(renderer: *Renderer, pane: *const Pane, buf: []const u8) void {
    const style = pane.float_style orelse return;
    const pos = style.position orelse return;

    const outer_x = pane.border_x;
    const outer_y = pane.border_y;
    const outer_w = pane.border_w;
    const outer_h = pane.border_h;
    if (outer_w < 3 or outer_h < 3) return;

    // Cap edit box to fit inside the border.
    const max_w: u16 = outer_w -| 4;
    if (max_w == 0) return;

    const want_w: u16 = @intCast(@min(@as(usize, max_w), @max(@as(usize, 1), buf.len + 1)));

    var draw_x: u16 = undefined;
    var draw_y: u16 = undefined;
    switch (pos) {
        .topleft => {
            draw_x = outer_x + 2;
            draw_y = outer_y;
        },
        .topcenter => {
            draw_x = outer_x + @as(u16, @intCast((outer_w -| want_w) / 2));
            draw_y = outer_y;
        },
        .topright => {
            draw_x = outer_x + outer_w -| 2 -| want_w;
            draw_y = outer_y;
        },
        .bottomleft => {
            draw_x = outer_x + 2;
            draw_y = outer_y + outer_h - 1;
        },
        .bottomcenter => {
            draw_x = outer_x + @as(u16, @intCast((outer_w -| want_w) / 2));
            draw_y = outer_y + outer_h - 1;
        },
        .bottomright => {
            draw_x = outer_x + outer_w -| 2 -| want_w;
            draw_y = outer_y + outer_h - 1;
        },
    }

    const bg: render.Color = .{ .palette = pane.border_color.active };
    const fg: render.Color = .{ .palette = 0 };

    // Background box.
    var i: u16 = 0;
    while (i < want_w) : (i += 1) {
        renderer.setCell(draw_x + i, draw_y, .{ .char = ' ', .fg = fg, .bg = bg });
    }

    // Text + cursor.
    const text_len: u16 = @intCast(@min(@as(usize, want_w - 1), buf.len));
    for (buf[0..text_len], 0..) |ch, idx| {
        renderer.setCell(draw_x + @as(u16, @intCast(idx)), draw_y, .{ .char = ch, .fg = fg, .bg = bg, .bold = true });
    }
    // Cursor marker at end (ASCII for portability).
    renderer.setCell(draw_x + text_len, draw_y, .{ .char = '|', .fg = fg, .bg = bg, .bold = true });
}
