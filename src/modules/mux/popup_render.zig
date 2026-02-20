const std = @import("std");
const pop = @import("pop");
const shp = @import("shp");
const vaxis = @import("vaxis");
const render = @import("render.zig");
const statusbar = @import("statusbar.zig");

pub const Renderer = render.Renderer;

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

    // Draw box background
    var y: u16 = box_y;
    while (y < box_y + box_height) : (y += 1) {
        var x: u16 = box_x;
        while (x < box_x + box_width) : (x += 1) {
            renderer.setCell(x, y, .{ .char = ' ', .fg = fg, .bg = bg });
        }
    }

    // Top border
    renderer.setCell(box_x, box_y, .{ .char = '┌', .fg = fg, .bg = bg });
    var x: u16 = box_x + 1;
    while (x < box_x + box_width - 1) : (x += 1) {
        renderer.setCell(x, box_y, .{ .char = '─', .fg = fg, .bg = bg });
    }
    renderer.setCell(box_x + box_width - 1, box_y, .{ .char = '┐', .fg = fg, .bg = bg });

    // Bottom border
    renderer.setCell(box_x, box_y + box_height - 1, .{ .char = '└', .fg = fg, .bg = bg });
    x = box_x + 1;
    while (x < box_x + box_width - 1) : (x += 1) {
        renderer.setCell(x, box_y + box_height - 1, .{ .char = '─', .fg = fg, .bg = bg });
    }
    renderer.setCell(box_x + box_width - 1, box_y + box_height - 1, .{ .char = '┘', .fg = fg, .bg = bg });

    // Side borders
    y = box_y + 1;
    while (y < box_y + box_height - 1) : (y += 1) {
        renderer.setCell(box_x, y, .{ .char = '│', .fg = fg, .bg = bg });
        renderer.setCell(box_x + box_width - 1, y, .{ .char = '│', .fg = fg, .bg = bg });
    }

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

    // Draw box background
    var y: u16 = box_y;
    while (y < box_y + box_height) : (y += 1) {
        var x: u16 = box_x;
        while (x < box_x + box_width) : (x += 1) {
            renderer.setCell(x, y, .{ .char = ' ', .fg = fg, .bg = bg });
        }
    }

    // Top border with optional title
    renderer.setCell(box_x, box_y, .{ .char = '┌', .fg = fg, .bg = bg });
    var x: u16 = box_x + 1;
    if (picker.title) |title| {
        renderer.setCell(x, box_y, .{ .char = '─', .fg = fg, .bg = bg });
        x += 1;
        renderer.setCell(x, box_y, .{ .char = ' ', .fg = fg, .bg = bg });
        x += 1;
        const title_max = (box_x + box_width - 2) -| x;
        const clipped_title = clipTextToWidth(title, title_max);
        x = statusbar.drawStyledText(renderer, x, box_y, clipped_title, popupTextStyle(fg, bg, true));
        renderer.setCell(x, box_y, .{ .char = ' ', .fg = fg, .bg = bg });
        x += 1;
    }
    while (x < box_x + box_width - 1) : (x += 1) {
        renderer.setCell(x, box_y, .{ .char = '─', .fg = fg, .bg = bg });
    }
    renderer.setCell(box_x + box_width - 1, box_y, .{ .char = '┐', .fg = fg, .bg = bg });

    // Bottom border
    renderer.setCell(box_x, box_y + box_height - 1, .{ .char = '└', .fg = fg, .bg = bg });
    x = box_x + 1;
    while (x < box_x + box_width - 1) : (x += 1) {
        renderer.setCell(x, box_y + box_height - 1, .{ .char = '─', .fg = fg, .bg = bg });
    }
    renderer.setCell(box_x + box_width - 1, box_y + box_height - 1, .{ .char = '┘', .fg = fg, .bg = bg });

    // Side borders
    y = box_y + 1;
    while (y < box_y + box_height - 1) : (y += 1) {
        renderer.setCell(box_x, y, .{ .char = '│', .fg = fg, .bg = bg });
        renderer.setCell(box_x + box_width - 1, y, .{ .char = '│', .fg = fg, .bg = bg });
    }

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
