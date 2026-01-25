const std = @import("std");
const pop = @import("pop");
const render = @import("render.zig");

pub const Renderer = render.Renderer;

/// Draw a blocking popup (confirm or picker) centered in bounds
pub fn drawInBounds(renderer: *Renderer, popup: pop.Popup, cfg: *const pop.CarrierConfig, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    switch (popup) {
        .confirm => |confirm| drawConfirmInBounds(renderer, confirm, cfg.confirm, bounds_x, bounds_y, bounds_w, bounds_h),
        .picker => |picker| drawPickerInBounds(renderer, picker, cfg.choose, bounds_x, bounds_y, bounds_w, bounds_h),
    }
}

/// Draw a blocking popup centered on full screen
pub fn draw(renderer: *Renderer, popup: pop.Popup, cfg: *const pop.CarrierConfig, term_width: u16, term_height: u16) void {
    drawInBounds(renderer, popup, cfg, 0, 0, term_width, term_height);
}

pub fn drawConfirmInBounds(renderer: *Renderer, confirm: *pop.Confirm, cfg: pop.ConfirmStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    const dims = confirm.getBoxDimensions();

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
    const msg = confirm.message;
    const msg_len: u16 = @intCast(@min(msg.len, inner_width - padding_x * 2));
    const msg_x = inner_x + padding_x + (inner_width - padding_x * 2 -| msg_len) / 2;
    for (msg[0..msg_len], 0..) |char, i| {
        const cx = msg_x + @as(u16, @intCast(i));
        if (cx < box_x + box_width - 1) {
            renderer.setCell(cx, msg_y, .{ .char = char, .fg = fg, .bg = bg, .bold = cfg.bold });
        }
    }

    // Draw buttons
    const buttons_y = msg_y + 2;
    const yes_label = confirm.yes_label;
    const no_label = confirm.no_label;

    const yes_text_len: u16 = @intCast(yes_label.len + 4);
    const no_text_len: u16 = @intCast(no_label.len + 4);
    const total_buttons_width = yes_text_len + 4 + no_text_len;
    const buttons_start_x = inner_x + (inner_width -| total_buttons_width) / 2;

    // Yes button
    const yes_selected = confirm.selected == .yes;
    const yes_fg: render.Color = if (yes_selected) bg else fg;
    const yes_bg: render.Color = if (yes_selected) fg else bg;
    var bx = buttons_start_x;
    renderer.setCell(bx, buttons_y, .{ .char = '[', .fg = yes_fg, .bg = yes_bg });
    bx += 1;
    renderer.setCell(bx, buttons_y, .{ .char = ' ', .fg = yes_fg, .bg = yes_bg });
    bx += 1;
    for (yes_label) |char| {
        renderer.setCell(bx, buttons_y, .{ .char = char, .fg = yes_fg, .bg = yes_bg, .bold = yes_selected });
        bx += 1;
    }
    renderer.setCell(bx, buttons_y, .{ .char = ' ', .fg = yes_fg, .bg = yes_bg });
    bx += 1;
    renderer.setCell(bx, buttons_y, .{ .char = ']', .fg = yes_fg, .bg = yes_bg });
    bx += 1;

    bx += 4; // spacing

    // No button
    const no_selected = confirm.selected == .no;
    const no_fg: render.Color = if (no_selected) bg else fg;
    const no_bg: render.Color = if (no_selected) fg else bg;
    renderer.setCell(bx, buttons_y, .{ .char = '[', .fg = no_fg, .bg = no_bg });
    bx += 1;
    renderer.setCell(bx, buttons_y, .{ .char = ' ', .fg = no_fg, .bg = no_bg });
    bx += 1;
    for (no_label) |char| {
        renderer.setCell(bx, buttons_y, .{ .char = char, .fg = no_fg, .bg = no_bg, .bold = no_selected });
        bx += 1;
    }
    renderer.setCell(bx, buttons_y, .{ .char = ' ', .fg = no_fg, .bg = no_bg });
    bx += 1;
    renderer.setCell(bx, buttons_y, .{ .char = ']', .fg = no_fg, .bg = no_bg });
}

pub fn drawPickerInBounds(renderer: *Renderer, picker: *pop.Picker, cfg: pop.ChooseStyle, bounds_x: u16, bounds_y: u16, bounds_w: u16, bounds_h: u16) void {
    const dims = picker.getBoxDimensions();

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
        for (title) |char| {
            if (x < box_x + box_width - 2) {
                renderer.setCell(x, box_y, .{ .char = char, .fg = fg, .bg = bg, .bold = true });
                x += 1;
            }
        }
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
        for (item) |char| {
            if (ix < box_x + box_width - 2) {
                renderer.setCell(ix, content_y, .{ .char = char, .fg = item_fg, .bg = item_bg, .bold = is_selected });
                ix += 1;
            }
        }
        while (ix < box_x + box_width - 1) : (ix += 1) {
            renderer.setCell(ix, content_y, .{ .char = ' ', .fg = item_fg, .bg = item_bg });
        }

        content_y += 1;
    }
}
