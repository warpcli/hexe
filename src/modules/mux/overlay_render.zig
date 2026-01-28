const std = @import("std");
const render = @import("render.zig");
const Renderer = render.Renderer;
const Color = render.Color;

const pop = @import("pop");
const overlay = pop.overlay;
const OverlayManager = overlay.OverlayManager;

const Pos = struct { x: u16, y: u16 };

/// Bounds of a rectangular area to exclude from dimming
pub const Bounds = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    pub fn contains(self: Bounds, px: u16, py: u16) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

/// Apply dimming effect to the entire screen, except the focused pane.
/// Sets foreground to 238 (dark gray) and background to 235 (darker gray).
pub fn applyDimEffect(renderer: *Renderer, width: u16, height: u16, exclude: ?Bounds) void {
    for (0..height) |yi| {
        for (0..width) |xi| {
            const x: u16 = @intCast(xi);
            const y: u16 = @intCast(yi);

            // Skip the focused pane area
            if (exclude) |bounds| {
                if (bounds.contains(x, y)) continue;
            }

            const cell = renderer.next.get(x, y);
            cell.fg = .{ .palette = 238 }; // dark gray text
            // Only dim bg if it's not already the default (none or black)
            switch (cell.bg) {
                .none => {},
                .palette => |p| {
                    if (p != 0) cell.bg = .{ .palette = 236 }; // dim colored backgrounds
                },
                .rgb => cell.bg = .{ .palette = 236 },
            }
        }
    }
}

/// Render all overlays to the screen.
pub fn renderOverlays(
    renderer: *Renderer,
    overlays: *OverlayManager,
    screen_width: u16,
    screen_height: u16,
    status_height: u16,
    focused_pane_bounds: ?Bounds,
) void {
    const content_height = screen_height - status_height;

    // Apply dimming if modal overlay is active (dims entire screen including status bar)
    if (overlays.shouldDim()) {
        applyDimEffect(renderer, screen_width, screen_height, focused_pane_bounds);
    }

    // Render pane select labels
    if (overlays.isPaneSelectActive()) {
        renderPaneSelectLabels(renderer, overlays);
    }

    // Render resize info
    if (overlays.isResizeInfoActive()) {
        renderResizeInfo(renderer, overlays);
    }

    // Render keycast
    if (overlays.keycast.hasContent()) {
        renderKeycast(renderer, &overlays.keycast, screen_width, content_height);
    }

    // Render generic overlays
    for (overlays.getOverlays()) |ov| {
        renderOverlay(renderer, ov, screen_width, content_height);
    }
}

/// Render pane select mode labels (big ASCII art numbers centered on each pane)
fn renderPaneSelectLabels(renderer: *Renderer, overlays: *OverlayManager) void {
    for (overlays.pane_select.getLabels()) |pl| {
        // Get the big digit pattern
        const digit = overlay.digits.getDigit(pl.label) orelse continue;

        const digit_w = overlay.digits.WIDTH;
        const digit_h = overlay.digits.HEIGHT;
        const padding: u16 = 1;
        const box_w = digit_w + padding * 2;
        const box_h = digit_h + padding * 2;

        // Check if pane is big enough for the digit
        if (pl.width < box_w or pl.height < box_h) {
            // Fall back to single character for small panes
            const cx = pl.x + pl.width / 2;
            const cy = pl.y + pl.height / 2;
            renderer.setCell(cx, cy, .{
                .char = pl.label,
                .fg = .{ .palette = 0 },
                .bg = .{ .palette = 1 },
                .bold = true,
            });
            continue;
        }

        // Center the box in the pane
        const box_x = pl.x + (pl.width -| box_w) / 2;
        const box_y = pl.y + (pl.height -| box_h) / 2;

        // Draw background box
        for (0..box_h) |dy| {
            for (0..box_w) |dx| {
                const x = box_x + @as(u16, @intCast(dx));
                const y = box_y + @as(u16, @intCast(dy));
                renderer.setCell(x, y, .{
                    .char = ' ',
                    .fg = .{ .palette = 0 },
                    .bg = .{ .palette = 1 }, // red background
                });
            }
        }

        // Draw the digit pattern using full block characters
        const digit_x = box_x + padding;
        const digit_y = box_y + padding;
        for (0..digit_h) |dy| {
            for (0..digit_w) |dx| {
                const ch = digit[dy][dx];
                if (ch != ' ') {
                    const x = digit_x + @as(u16, @intCast(dx));
                    const y = digit_y + @as(u16, @intCast(dy));
                    renderer.setCell(x, y, .{
                        .char = ch,
                        .fg = .{ .palette = 0 }, // black blocks
                        .bg = .{ .palette = 1 }, // red background
                    });
                }
            }
        }
    }
}

/// Render resize info overlay
fn renderResizeInfo(renderer: *Renderer, overlays: *OverlayManager) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}x{d} @ {d},{d}", .{
        overlays.resize_info_width,
        overlays.resize_info_height,
        overlays.resize_info_x,
        overlays.resize_info_y,
    }) catch return;

    const text_len: u16 = @intCast(text.len);
    const padding: u16 = 1;
    const box_width = text_len + padding * 2;
    const box_height: u16 = 1;

    const cx = overlays.resize_info_x + overlays.resize_info_width / 2;
    const cy = overlays.resize_info_y + overlays.resize_info_height / 2;

    const box_x = cx -| (box_width / 2);
    const box_y = cy -| (box_height / 2);

    // Draw background
    for (0..box_width) |dx| {
        const x = box_x + @as(u16, @intCast(dx));
        renderer.setCell(x, box_y, .{
            .char = ' ',
            .fg = .{ .palette = 0 },
            .bg = .{ .palette = 1 }, // red
        });
    }

    // Draw text
    for (text, 0..) |ch, i| {
        renderer.setCell(box_x + padding + @as(u16, @intCast(i)), box_y, .{
            .char = ch,
            .fg = .{ .palette = 0 }, // black
            .bg = .{ .palette = 1 }, // red
        });
    }
}

/// Render keycast history in bottom-right corner
fn renderKeycast(renderer: *Renderer, keycast_state: *const overlay.KeycastState, screen_width: u16, content_height: u16) void {
    const entries = keycast_state.getEntries();
    if (entries.len == 0) return;

    const margin: u16 = 2;
    var y = content_height -| margin -| @as(u16, @intCast(entries.len));

    for (entries) |entry| {
        const text = entry.getText();
        const text_len: u16 = @intCast(text.len);
        const padding: u16 = 1;
        const box_width = text_len + padding * 2;

        const box_x = screen_width -| margin -| box_width;

        // Draw background
        for (0..box_width) |dx| {
            const x = box_x + @as(u16, @intCast(dx));
            renderer.setCell(x, y, .{
                .char = ' ',
                .fg = .{ .palette = 15 },
                .bg = .{ .palette = 238 }, // dark gray
            });
        }

        // Draw text
        for (text, 0..) |ch, ci| {
            renderer.setCell(box_x + padding + @as(u16, @intCast(ci)), y, .{
                .char = ch,
                .fg = .{ .palette = 15 },
                .bg = .{ .palette = 238 },
                .bold = true,
            });
        }

        y += 1;
    }
}

/// Render a generic overlay
fn renderOverlay(renderer: *Renderer, ov: overlay.Overlay, screen_width: u16, screen_height: u16) void {
    const text_len: u16 = @intCast(@min(ov.text.len, 80));
    if (text_len == 0) return;

    const box_width = text_len + @as(u16, ov.padding_x) * 2;
    const box_height: u16 = 1 + @as(u16, ov.padding_y) * 2;

    const pos: Pos = switch (ov.position) {
        .corner => |c| calculateCornerPosition(c.anchor, c.offset_x, c.offset_y, box_width, box_height, screen_width, screen_height),
        .absolute => |a| .{ .x = a.x, .y = a.y },
        .pane_center => .{ .x = screen_width / 2 -| box_width / 2, .y = screen_height / 2 -| box_height / 2 },
    };

    // Draw background
    for (0..box_height) |dy| {
        for (0..box_width) |dx| {
            const x = pos.x + @as(u16, @intCast(dx));
            const y = pos.y + @as(u16, @intCast(dy));
            renderer.setCell(x, y, .{
                .char = ' ',
                .fg = .{ .palette = ov.fg },
                .bg = .{ .palette = ov.bg },
            });
        }
    }

    // Draw text
    const text_x = pos.x + ov.padding_x;
    const text_y = pos.y + ov.padding_y;
    for (0..text_len) |i| {
        renderer.setCell(text_x + @as(u16, @intCast(i)), text_y, .{
            .char = ov.text[i],
            .fg = .{ .palette = ov.fg },
            .bg = .{ .palette = ov.bg },
            .bold = ov.bold,
        });
    }
}

fn calculateCornerPosition(
    anchor: overlay.Corner,
    offset_x: u16,
    offset_y: u16,
    box_width: u16,
    box_height: u16,
    screen_width: u16,
    screen_height: u16,
) Pos {
    return switch (anchor) {
        .top_left => .{ .x = offset_x, .y = offset_y },
        .top_right => .{ .x = screen_width -| box_width -| offset_x, .y = offset_y },
        .bottom_left => .{ .x = offset_x, .y = screen_height -| box_height -| offset_y },
        .bottom_right => .{ .x = screen_width -| box_width -| offset_x, .y = screen_height -| box_height -| offset_y },
        .center => .{ .x = screen_width / 2 -| box_width / 2, .y = screen_height / 2 -| box_height / 2 },
    };
}
