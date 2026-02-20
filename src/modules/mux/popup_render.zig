const std = @import("std");
const pop = @import("pop");
const shp = @import("shp");
const vaxis = @import("vaxis");
const render = @import("render.zig");
const statusbar = @import("statusbar.zig");

pub const Renderer = render.Renderer;

fn toVaxisColor(c: render.Color) vaxis.Color {
    return switch (c) {
        .none => .default,
        .palette => |idx| .{ .index = idx },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}

fn toRenderCell(vx_cell: vaxis.Cell) render.Cell {
    var out: render.Cell = .{
        .char = ' ',
        .bold = vx_cell.style.bold,
        .italic = vx_cell.style.italic,
        .faint = vx_cell.style.dim,
        .strikethrough = vx_cell.style.strikethrough,
        .inverse = vx_cell.style.reverse,
    };

    out.fg = switch (vx_cell.style.fg) {
        .default => .none,
        .index => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } },
    };
    out.bg = switch (vx_cell.style.bg) {
        .default => .none,
        .index => |idx| .{ .palette = idx },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] } },
    };
    out.underline = switch (vx_cell.style.ul_style) {
        .off => .none,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };

    if (vx_cell.char.width == 0 or vx_cell.char.grapheme.len == 0) {
        out.char = 0;
        out.is_wide_spacer = true;
        return out;
    }

    out.char = std.unicode.utf8Decode(vx_cell.char.grapheme) catch ' ';
    out.is_wide_char = vx_cell.char.width == 2;
    return out;
}

fn drawPopupFrame(renderer: *Renderer, x: u16, y: u16, w: u16, h: u16, fg: render.Color, bg: render.Color, title: ?[]const u8) void {
    if (w == 0 or h == 0) return;

    var screen = vaxis.Screen.init(std.heap.page_allocator, .{ .cols = w, .rows = h, .x_pixel = 0, .y_pixel = 0 }) catch return;
    defer screen.deinit(std.heap.page_allocator);
    screen.width_method = .unicode;

    const root: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = w,
        .height = h,
        .screen = &screen,
    };

    const base_style: vaxis.Style = .{ .fg = toVaxisColor(fg), .bg = toVaxisColor(bg) };
    root.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = base_style });
    _ = root.child(.{
        .width = w,
        .height = h,
        .border = .{
            .where = .all,
            .glyphs = .single_square,
            .style = base_style,
        },
    });

    if (title) |t| {
        if (h > 0 and w > 4) {
            const clipped = clipTextToWidth(t, w - 4);
            const title_segments = &[_]vaxis.Segment{
                .{ .text = " ", .style = base_style },
                .{ .text = clipped, .style = .{ .fg = toVaxisColor(fg), .bg = toVaxisColor(bg), .bold = true } },
                .{ .text = " ", .style = base_style },
            };
            _ = root.print(title_segments, .{ .row_offset = 0, .col_offset = 2, .wrap = .none, .commit = true });
        }
    }

    for (0..h) |ry| {
        for (0..w) |rx| {
            const vx_cell = screen.readCell(@intCast(rx), @intCast(ry)) orelse continue;
            renderer.setCell(x + @as(u16, @intCast(rx)), y + @as(u16, @intCast(ry)), toRenderCell(vx_cell));
        }
    }
}

fn textWidth(text: []const u8) u16 {
    return statusbar.measureText(text);
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

fn popupTextStyle(fg: render.Color, bg: render.Color, bold: bool) shp.Style {
    return .{
        .fg = switch (fg) {
            .none => .none,
            .palette => |idx| .{ .palette = idx },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        },
        .bg = switch (bg) {
            .none => .none,
            .palette => |idx| .{ .palette = idx },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        },
        .bold = bold,
    };
}

/// Draw a blocking popup (confirm or picker) centered in bounds
pub fn drawInBounds(renderer: *Renderer, popup: pop.Popup, cfg: anytype, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    switch (popup) {
        .confirm => |confirm| drawConfirmInBounds(renderer, confirm, cfg.confirm, bounds_x, bounds_y, bounds_w, bounds_h),
        .picker => |picker| drawPickerInBounds(renderer, picker, cfg.choose, bounds_x, bounds_y, bounds_w, bounds_h),
    }
}

/// Draw a blocking popup centered on full screen
pub fn draw(renderer: *Renderer, popup: pop.Popup, cfg: anytype, term_width: u16, term_height: u16) void {
    drawInBounds(renderer, popup, cfg, 0, 0, term_width, term_height);
}

fn confirmBoxDimensions(confirm: *pop.Confirm, cfg: pop.ConfirmStyle) struct { width: u16, height: u16 } {
    const msg_width: u16 = textWidth(confirm.message);
    const buttons_width: u16 = textWidth(confirm.yes_label) + textWidth(confirm.no_label) + 14;
    const content_width = @max(msg_width, buttons_width);
    const box_width = content_width + cfg.padding_x * 2 + 2;
    const box_height: u16 = 3 + cfg.padding_y * 2 + 2;
    return .{ .width = box_width, .height = box_height };
}

fn pickerBoxDimensions(picker: *pop.Picker, cfg: pop.ChooseStyle) struct { width: u16, height: u16 } {
    var max_item_width: usize = 0;
    for (picker.items) |item| {
        max_item_width = @max(max_item_width, textWidth(item));
    }

    var title_width: usize = 0;
    if (picker.title) |t| {
        title_width = textWidth(t) + 4;
    }

    const content_width = @max(max_item_width + 2, title_width);
    const box_width: u16 = @intCast(content_width + cfg.padding_x * 2);

    var box_height: u16 = @intCast(picker.visible_count + cfg.padding_y * 2);
    if (picker.title != null) {
        box_height += 1;
    }
    return .{ .width = box_width, .height = box_height };
}

pub fn drawConfirmInBounds(renderer: *Renderer, confirm: *pop.Confirm, cfg: pop.ConfirmStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    const dims = confirmBoxDimensions(confirm, cfg);

    const min_width: u16 = 30;
    const box_width = @max(dims.width, min_width);
    const box_height = dims.height;

    const center_x = bounds_x + bounds_w / 2;
    const center_y = bounds_y + bounds_h / 2;
    const box_x = center_x -| (box_width / 2);
    const box_y = center_y -| (box_height / 2);

    const fg: render.Color = .{ .palette = cfg.fg };
    const bg: render.Color = .{ .palette = cfg.bg };
    const padding_x = cfg.padding_x;
    const padding_y = cfg.padding_y;

    const inner_width = box_width - 2;
    const inner_x = box_x + 1;

    drawPopupFrame(renderer, box_x, box_y, box_width, box_height, fg, bg, null);

    // Draw message
    const msg_y = box_y + 1 + padding_y;
    const max_msg_width = inner_width -| padding_x * 2;
    const msg = clipTextToWidth(confirm.message, max_msg_width);
    const msg_len: u16 = textWidth(msg);
    const msg_x = inner_x + padding_x + (max_msg_width -| msg_len) / 2;
    _ = statusbar.drawStyledText(renderer, msg_x, msg_y, msg, popupTextStyle(fg, bg, cfg.bold));

    // Draw buttons
    const buttons_y = msg_y + 2;
    const yes_label = confirm.yes_label;
    const no_label = confirm.no_label;

    const yes_text_len: u16 = textWidth(yes_label) + 4;
    const no_text_len: u16 = textWidth(no_label) + 4;
    const total_buttons_width = yes_text_len + 4 + no_text_len;
    const buttons_start_x = inner_x + (inner_width -| total_buttons_width) / 2;

    // Yes button
    const yes_selected = confirm.selected == .yes;
    const yes_fg: render.Color = if (yes_selected) bg else fg;
    const yes_bg: render.Color = if (yes_selected) fg else bg;
    var bx = buttons_start_x;
    const yes_style = popupTextStyle(yes_fg, yes_bg, yes_selected);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, "[ ", yes_style);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, yes_label, yes_style);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, " ]", yes_style);

    bx += 4; // spacing

    // No button
    const no_selected = confirm.selected == .no;
    const no_fg: render.Color = if (no_selected) bg else fg;
    const no_bg: render.Color = if (no_selected) fg else bg;
    const no_style = popupTextStyle(no_fg, no_bg, no_selected);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, "[ ", no_style);
    bx = statusbar.drawStyledText(renderer, bx, buttons_y, no_label, no_style);
    _ = statusbar.drawStyledText(renderer, bx, buttons_y, " ]", no_style);
}

pub fn drawPickerInBounds(renderer: *Renderer, picker: *pop.Picker, cfg: pop.ChooseStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    const dims = pickerBoxDimensions(picker, cfg);

    const min_width: u16 = 20;
    const box_width = @max(dims.width, min_width);
    const box_height = dims.height + 2;

    const center_x = bounds_x + bounds_w / 2;
    const center_y = bounds_y + bounds_h / 2;
    const box_x = center_x -| (box_width / 2);
    const box_y = center_y -| (box_height / 2);

    const fg: render.Color = .{ .palette = cfg.fg };
    const bg: render.Color = .{ .palette = cfg.bg };
    const highlight_fg: render.Color = .{ .palette = cfg.highlight_fg };
    const highlight_bg: render.Color = .{ .palette = cfg.highlight_bg };

    drawPopupFrame(renderer, box_x, box_y, box_width, box_height, fg, bg, picker.title);

    // Draw items
    const content_x = box_x + 2;
    var content_y = box_y + 1;
    const visible_end = @min(picker.scroll_offset + picker.visible_count, picker.items.len);

    var i = picker.scroll_offset;
    while (i < visible_end) : (i += 1) {
        const item = picker.items[i];
        const is_selected = i == picker.selected;
        const item_fg: render.Color = if (is_selected) highlight_fg else fg;
        const item_bg: render.Color = if (is_selected) highlight_bg else bg;

        renderer.setCell(content_x, content_y, .{ .char = if (is_selected) '>' else ' ', .fg = item_fg, .bg = item_bg });
        renderer.setCell(content_x + 1, content_y, .{ .char = ' ', .fg = item_fg, .bg = item_bg });

        var ix: u16 = content_x + 2;
        const item_width_max = (box_x + box_width - 2) -| ix;
        const clipped_item = clipTextToWidth(item, item_width_max);
        ix = statusbar.drawStyledText(renderer, ix, content_y, clipped_item, popupTextStyle(item_fg, item_bg, is_selected));
        while (ix < box_x + box_width - 1) : (ix += 1) {
            renderer.setCell(ix, content_y, .{ .char = ' ', .fg = item_fg, .bg = item_bg });
        }

        content_y += 1;
    }
}
