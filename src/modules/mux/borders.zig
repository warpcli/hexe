const std = @import("std");
const core = @import("core");
const render = @import("render.zig");
const statusbar = @import("statusbar.zig");
const Pane = @import("pane.zig").Pane;
const Layout = @import("layout.zig").Layout;

pub const Renderer = render.Renderer;

/// Draw split borders between panes
pub fn drawSplitBorders(
    renderer: *Renderer,
    layout: *Layout,
    splits_cfg: *const core.config.SplitsConfig,
    term_width: u16,
    content_height: u16,
) void {
    // Get characters and color from config
    const v_char: u21 = if (splits_cfg.style) |s| s.vertical else splits_cfg.separator_v;
    const h_char: u21 = if (splits_cfg.style) |s| s.horizontal else splits_cfg.separator_h;
    const color: u8 = splits_cfg.color.passive; // splits use passive color

    // Junction characters (only used if style is set)
    const cross_char: u21 = if (splits_cfg.style) |s| s.cross else v_char;
    const top_t: u21 = if (splits_cfg.style) |s| s.top_t else v_char;
    const bottom_t: u21 = if (splits_cfg.style) |s| s.bottom_t else v_char;
    const left_t: u21 = if (splits_cfg.style) |s| s.left_t else h_char;
    const right_t: u21 = if (splits_cfg.style) |s| s.right_t else h_char;

    // Collect vertical and horizontal line positions
    var v_lines: [64]u16 = undefined;
    var v_line_count: usize = 0;
    var h_lines: [64]u16 = undefined;
    var h_line_count: usize = 0;

    var pane_it = layout.splitIterator();
    while (pane_it.next()) |pane| {
        const right_edge = pane.*.x + pane.*.width;
        const bottom_edge = pane.*.y + pane.*.height;

        // Record vertical line position
        if (right_edge < term_width and v_line_count < v_lines.len) {
            // Check if already recorded
            var found = false;
            for (v_lines[0..v_line_count]) |x| {
                if (x == right_edge) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                v_lines[v_line_count] = right_edge;
                v_line_count += 1;
            }
        }

        // Record horizontal line position
        if (bottom_edge < content_height and h_line_count < h_lines.len) {
            var found = false;
            for (h_lines[0..h_line_count]) |y| {
                if (y == bottom_edge) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                h_lines[h_line_count] = bottom_edge;
                h_line_count += 1;
            }
        }
    }

    // Draw vertical lines - but only where there's actually a split boundary
    for (v_lines[0..v_line_count]) |x| {
        for (0..content_height) |row| {
            const y: u16 = @intCast(row);

            // Check if this row actually has a vertical boundary at this x
            // A vertical line should only be drawn where a pane ends (right_edge == x)
            // and that row is within that pane's y range
            var should_draw = false;
            var pane_check = layout.splitIterator();
            while (pane_check.next()) |pane| {
                const right_edge = pane.*.x + pane.*.width;
                if (right_edge == x) {
                    // Check if y is within this pane's vertical range
                    if (y >= pane.*.y and y < pane.*.y + pane.*.height) {
                        should_draw = true;
                        break;
                    }
                }
            }

            if (!should_draw) continue;

            var char = v_char;

            // Check for junctions with horizontal lines
            if (splits_cfg.style != null) {
                for (h_lines[0..h_line_count]) |hy| {
                    if (y == hy) {
                        // Check if this is a cross, top_t, or bottom_t
                        const at_top = (y == 0);
                        const at_bottom = (y == content_height - 1);
                        if (at_top) {
                            char = top_t;
                        } else if (at_bottom) {
                            char = bottom_t;
                        } else {
                            char = cross_char;
                        }
                        break;
                    }
                }
            }

            renderer.setCell(x, y, .{ .char = char, .fg = .{ .palette = color } });
        }
    }

    // Draw horizontal lines - but only where there's actually a split boundary
    for (h_lines[0..h_line_count]) |y| {
        for (0..term_width) |col| {
            const x: u16 = @intCast(col);

            // Skip if already drawn by vertical line (junction)
            var is_junction = false;
            for (v_lines[0..v_line_count]) |vx| {
                if (x == vx) {
                    is_junction = true;
                    break;
                }
            }
            if (is_junction) continue;

            // Check if this column actually has a horizontal boundary at this y
            // A horizontal line should only be drawn where a pane ends (bottom_edge == y)
            // and that column is within that pane's x range
            var should_draw = false;
            var pane_check = layout.splitIterator();
            while (pane_check.next()) |pane| {
                const bottom_edge = pane.*.y + pane.*.height;
                if (bottom_edge == y) {
                    // Check if x is within this pane's horizontal range
                    if (x >= pane.*.x and x < pane.*.x + pane.*.width) {
                        should_draw = true;
                        break;
                    }
                }
            }

            if (!should_draw) continue;

            var char = h_char;

            // Check for edge junctions
            if (splits_cfg.style != null) {
                const at_left = (x == 0);
                const at_right = (x == term_width - 1);
                if (at_left) {
                    char = left_t;
                } else if (at_right) {
                    char = right_t;
                }
            }

            renderer.setCell(x, y, .{ .char = char, .fg = .{ .palette = color } });
        }
    }
}

/// Draw scroll indicator at top of pane when scrolled
pub fn drawScrollIndicator(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16) void {
    // Display a scroll indicator at top-right of pane
    const indicator_chars = [_]u21{ ' ', 0x25b2, 0x25b2, 0x25b2, ' ' };

    // Position at top-right corner (inside pane bounds)
    const indicator_len: u16 = 5;
    const x_pos = pane_x + pane_width -| indicator_len;

    // Yellow background (palette 3), black text (palette 0)
    for (indicator_chars, 0..) |char, i| {
        renderer.setCell(x_pos + @as(u16, @intCast(i)), pane_y, .{
            .char = char,
            .fg = .{ .palette = 0 }, // black
            .bg = .{ .palette = 3 }, // yellow
        });
    }
}

/// Draw border around a floating pane
pub fn drawFloatingBorder(
    renderer: *Renderer,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    active: bool,
    name: []const u8,
    border_color: core.BorderColor,
    style: ?*const core.FloatStyle,
) void {
    // Optional shadow (draw first so border overlays it)
    if (style) |s| {
        if (s.shadow_color) |sc| {
            const shadow_bg: render.Color = .{ .palette = sc };
            const shadow_fg: render.Color = .{ .palette = sc };
            const sx: u16 = x + w;
            const sy: u16 = y + h;

            // Right shadow: start 1 row below the top border, and stop 1 row
            // above the bottom border so the corner is "owned" by the bottom
            // shadow.
            if (h > 2) {
                var row: u16 = 1;
                while (row < h - 1) : (row += 1) {
                    renderer.setCell(sx, y + row, .{ .char = ' ', .bg = shadow_bg });
                }
            }

            // Add a small "cap" next to the bottom border so there is no
            // visible gap between the side shadow and the bottom shadow.
            if (h > 1) {
                renderer.setCell(sx, y + h - 1, .{ .char = ' ', .bg = shadow_bg });
            }

            // Bottom shadow: start 1 col after left border, and include the
            // corner cell (so it extends one further than the right shadow).
            var col: u16 = 1;
            while (col <= w) : (col += 1) {
                // Use upper-half block for bottom shadow so it feels visually
                // closer in "weight" to the 1-col side shadow.
                renderer.setCell(x + col, sy, .{ .char = 0x2580, .fg = shadow_fg });
            }
            // Corner is already drawn by the bottom shadow (col == w).
        }
    }

    const color = if (active) border_color.active else border_color.passive;
    const fg: render.Color = .{ .palette = color };
    // Do not rely on SGR bold for active borders.
    // Many terminals render bold + low palette indices as the "bright" variant
    // (e.g. palette 1 looks like palette 9). We want the configured palette
    // index to be respected.
    const bold = false;

    // Get border characters from style or use defaults
    const top_left: u21 = if (style) |s| s.top_left else 0x256D;
    const top_right: u21 = if (style) |s| s.top_right else 0x256E;
    const bottom_left: u21 = if (style) |s| s.bottom_left else 0x2570;
    const bottom_right: u21 = if (style) |s| s.bottom_right else 0x256F;
    const horizontal: u21 = if (style) |s| s.horizontal else 0x2500;
    const vertical: u21 = if (style) |s| s.vertical else 0x2502;


    // Clear the interior with spaces first
    for (1..h -| 1) |row| {
        for (1..w -| 1) |col| {
            renderer.setCell(x + @as(u16, @intCast(col)), y + @as(u16, @intCast(row)), .{
                .char = ' ',
            });
        }
    }

    // Top-left corner
    renderer.setCell(x, y, .{ .char = top_left, .fg = fg, .bold = bold });

    // Top border (no built-in title).
    // The float title should be rendered via the style module area so the
    // user fully controls title placement and formatting.
    for (0..w -| 2) |col| {
        renderer.setCell(x + @as(u16, @intCast(col)) + 1, y, .{ .char = horizontal, .fg = fg, .bold = bold });
    }

    // Top-right corner
    renderer.setCell(x + w - 1, y, .{ .char = top_right, .fg = fg, .bold = bold });

    // Side borders
    for (1..h -| 1) |row| {
        renderer.setCell(x, y + @as(u16, @intCast(row)), .{ .char = vertical, .fg = fg, .bold = bold });
        renderer.setCell(x + w - 1, y + @as(u16, @intCast(row)), .{ .char = vertical, .fg = fg, .bold = bold });
    }

    // Bottom-left corner
    renderer.setCell(x, y + h - 1, .{ .char = bottom_left, .fg = fg, .bold = bold });

    // Bottom border
    for (0..w -| 2) |col| {
        renderer.setCell(x + @as(u16, @intCast(col)) + 1, y + h - 1, .{ .char = horizontal, .fg = fg, .bold = bold });
    }

    // Bottom-right corner
    renderer.setCell(x + w - 1, y + h - 1, .{ .char = bottom_right, .fg = fg, .bold = bold });

    // Render module in border if present
    if (style) |s| {
        if (s.module) |*module| {
            if (s.position) |pos| {
                // Run the module to get output
                var output_buf: [256]u8 = undefined;
                // If a title is provided, treat the module area as the title widget.
                const output = if (name.len > 0)
                    name
                else
                    statusbar.runStatusModule(module, &output_buf) catch "";
                if (output.len == 0) return;

                // Render styled output
                const segments = statusbar.renderModuleOutput(module, output);

                // Calculate position based on style position
                const total_len = segments.total_len;
                var draw_x: u16 = undefined;
                var draw_y: u16 = undefined;

                switch (pos) {
                    .topleft => {
                        draw_x = x + 2;
                        draw_y = y;
                    },
                    .topcenter => {
                        draw_x = x + @as(u16, @intCast((w -| total_len) / 2));
                        draw_y = y;
                    },
                    .topright => {
                        draw_x = x + w -| 2 -| @as(u16, @intCast(total_len));
                        draw_y = y;
                    },
                    .bottomleft => {
                        draw_x = x + 2;
                        draw_y = y + h - 1;
                    },
                    .bottomcenter => {
                        draw_x = x + @as(u16, @intCast((w -| total_len) / 2));
                        draw_y = y + h - 1;
                    },
                    .bottomright => {
                        draw_x = x + w -| 2 -| @as(u16, @intCast(total_len));
                        draw_y = y + h - 1;
                    },
                }

                // Draw each segment with its style
                var cur_x = draw_x;
                for (segments.items[0..segments.count]) |seg| {
                    for (seg.text) |ch| {
                        renderer.setCell(cur_x, draw_y, .{
                            .char = ch,
                            .fg = seg.fg,
                            .bg = seg.bg,
                            .bold = seg.bold,
                            .italic = seg.italic,
                        });
                        cur_x += 1;
                    }
                }
            }
        }
    }
}
