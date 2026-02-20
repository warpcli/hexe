const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");

const pagepkg = ghostty.page;
const Style = ghostty.Style;
const RenderState = ghostty.RenderState;

/// Static ASCII lookup table -- avoids arena allocation for 95%+ of cells.
/// Each byte position i contains the byte value i, so ascii_lut[ch..][0..1]
/// is a valid single-byte slice for any ASCII codepoint.
const ascii_lut: [128]u8 = initAsciiLut();

fn initAsciiLut() [128]u8 {
    var table: [128]u8 = undefined;
    for (0..128) |i| table[i] = @intCast(i);
    return table;
}

/// Blit ghostty RenderState into a vaxis Window.
///
/// Follows prise's server.zig pattern for content_tag dispatch,
/// grapheme encoding, and wide-character spacer handling.
///
/// `arena` is a frame-scoped allocator for temporary grapheme UTF-8 strings.
/// It must remain valid until after `vx.render()` completes for this frame.
pub fn drawRenderState(
    win: vaxis.Window,
    state: *const RenderState,
    width: u16,
    height: u16,
    arena: std.mem.Allocator,
) void {
    const MAX_REASONABLE_ROWS: usize = 10_000;
    const MAX_REASONABLE_COLS: usize = 1_000;

    const safe_rows = @min(@as(usize, state.rows), MAX_REASONABLE_ROWS);
    const safe_cols = @min(@as(usize, state.cols), MAX_REASONABLE_COLS);
    const rows = @min(@as(usize, height), safe_rows);
    const cols = @min(@as(usize, width), safe_cols);

    const row_slice = state.row_data.slice();
    const available_rows = @min(rows, row_slice.len);
    if (available_rows == 0) return;

    const row_cells = row_slice.items(.cells);

    for (0..available_rows) |yi| {
        const y: u16 = @intCast(yi);
        if (y >= win.height) break;

        const cells_slice = row_cells[yi].slice();
        const raw_cells = cells_slice.items(.raw);
        const styles_arr = cells_slice.items(.style);

        var col: usize = 0;
        while (col < cols) {
            const x: u16 = @intCast(col);
            if (x >= win.width) break;

            const raw = raw_cells[col];

            // Skip spacer tails (prise: server.zig:930-933)
            if (raw.wide == .spacer_tail) {
                col += 1;
                continue;
            }

            const cell_width: u8 = if (raw.wide == .wide) 2 else 1;
            const is_direct_color = (raw.content_tag == .bg_color_rgb or
                raw.content_tag == .bg_color_palette);

            // Resolve grapheme text
            const text = resolveCellText(arena, raw, is_direct_color) catch " ";

            // Resolve style
            const style = if (raw.style_id != 0)
                convertStyle(styles_arr[col], raw, is_direct_color)
            else
                convertDefaultStyle(raw, is_direct_color);

            win.writeCell(@intCast(col), y, .{
                .char = .{ .grapheme = text, .width = cell_width },
                .style = style,
            });

            // Write explicit spacer cells for wide characters
            // (prise: Surface.zig:264-270)
            if (cell_width == 2 and col + 1 < cols and x + 1 < win.width) {
                win.writeCell(x + 1, y, .{
                    .char = .{ .grapheme = "", .width = 0 },
                    .style = style,
                });
            }

            col += cell_width;
        }
    }
}

/// Convert ghostty cell content to a UTF-8 string.
/// Handles single codepoints AND multi-codepoint grapheme clusters.
/// (prise: server.zig:844-871)
fn resolveCellText(
    alloc: std.mem.Allocator,
    raw: pagepkg.Cell,
    is_direct_color: bool,
) ![]const u8 {
    if (is_direct_color) return " ";

    const cp = raw.codepoint();
    if (cp == 0 or cp < 32 or cp == 127) return " ";

    // Spacer head (end-of-line wide char wrap) -> blank
    if (raw.wide == .spacer_head) return " ";

    // Fast path: single ASCII codepoint (95%+ of terminal content)
    if (cp < 128) return ascii_lut[cp..][0..1];

    // Non-ASCII: encode to UTF-8 via arena
    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return " ";
    return try alloc.dupe(u8, utf8_buf[0..len]);
}

/// Convert ghostty Style to vaxis Style.
/// (prise: server.zig:686-743)
fn convertStyle(gs: Style, raw: pagepkg.Cell, is_direct_color: bool) vaxis.Style {
    var style = vaxis.Style{};

    // Foreground
    switch (gs.fg_color) {
        .none => {},
        .palette => |idx| style.fg = .{ .index = @intCast(idx) },
        .rgb => |rgb| style.fg = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    }

    // Background
    switch (gs.bg_color) {
        .none => {},
        .palette => |idx| style.bg = .{ .index = @intCast(idx) },
        .rgb => |rgb| style.bg = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    }

    // Direct color cells override bg (prise: server.zig:938-946)
    if (is_direct_color) {
        applyDirectColor(&style, raw);
    }

    // Underline color
    switch (gs.underline_color) {
        .none => {},
        .palette => {},
        .rgb => |rgb| style.ul = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    }

    // Flags (prise: server.zig:725-740)
    style.bold = gs.flags.bold;
    style.dim = gs.flags.faint;
    style.italic = gs.flags.italic;
    style.reverse = gs.flags.inverse;
    style.blink = gs.flags.blink;
    style.strikethrough = gs.flags.strikethrough;

    style.ul_style = switch (gs.flags.underline) {
        .none => .off,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };

    return style;
}

fn convertDefaultStyle(raw: pagepkg.Cell, is_direct_color: bool) vaxis.Style {
    var style = vaxis.Style{};
    if (is_direct_color) applyDirectColor(&style, raw);
    return style;
}

fn applyDirectColor(style: *vaxis.Style, raw: pagepkg.Cell) void {
    if (raw.content_tag == .bg_color_rgb) {
        const c = raw.content.color_rgb;
        style.bg = .{ .rgb = .{ c.r, c.g, c.b } };
    } else if (raw.content_tag == .bg_color_palette) {
        style.bg = .{ .index = raw.content.color_palette };
    }
}

/// Convert a hexa-style Color union to vaxis Color.
/// Used during the migration period while some code still uses the old Color type.
pub fn colorToVaxis(c: anytype) vaxis.Cell.Color {
    return switch (c) {
        .none => .default,
        .palette => |p| .{ .index = p },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}
