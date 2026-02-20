const ghostty = @import("ghostty-vt");
const render_types = @import("render_types.zig");
const render_buffer = @import("render_buffer.zig");

const Cell = render_types.Cell;
const Color = render_types.Color;
const CellBuffer = render_buffer.CellBuffer;

/// Draw a pane viewport RenderState into a cell buffer at the given offset.
pub fn drawRenderStateToBuffer(
    next: *CellBuffer,
    state: *const ghostty.RenderState,
    offset_x: u16,
    offset_y: u16,
    width: u16,
    height: u16,
) void {
    const MAX_REASONABLE_ROWS: usize = 10_000;
    const MAX_REASONABLE_COLS: usize = 1_000;

    const row_slice = state.row_data.slice();

    const safe_state_rows = @min(@as(usize, state.rows), MAX_REASONABLE_ROWS);
    const safe_state_cols = @min(@as(usize, state.cols), MAX_REASONABLE_COLS);

    const rows = @min(@as(usize, height), safe_state_rows);
    const cols = @min(@as(usize, width), safe_state_cols);

    const available_rows = @min(rows, row_slice.len);
    if (available_rows == 0) return;

    const row_cells = row_slice.items(.cells);

    const max_write_x = next.width;
    const max_write_y = next.height;

    for (0..available_rows) |yi| {
        const y: u16 = @intCast(yi);
        if (offset_y + y >= max_write_y) break;

        const cells_slice = row_cells[yi].slice();
        const raw_cells = cells_slice.items(.raw);
        const styles = cells_slice.items(.style);

        for (0..cols) |xi| {
            const x: u16 = @intCast(xi);
            if (offset_x + x >= max_write_x) break;

            const raw = raw_cells[xi];

            var render_cell = Cell{};
            render_cell.char = raw.codepoint();

            if (render_cell.char == 0) {
                render_cell.char = ' ';
            }

            if (render_cell.char < 32 or render_cell.char == 127) {
                render_cell.char = ' ';
            }

            if (raw.wide == .spacer_tail) {
                render_cell.char = 0;
                render_cell.is_wide_spacer = true;
                setCell(next, offset_x + x, offset_y + y, render_cell);
                continue;
            }

            if (raw.wide == .spacer_head) {
                render_cell.char = ' ';
            }

            if (raw.wide == .wide) {
                render_cell.is_wide_char = true;
            }

            if (raw.style_id != 0) {
                const style = styles[xi];
                render_cell.fg = Color.fromStyleColor(style.fg_color);
                render_cell.bg = Color.fromStyleColor(style.bg_color);
                render_cell.bold = style.flags.bold;
                render_cell.italic = style.flags.italic;
                render_cell.faint = style.flags.faint;
                render_cell.underline = @enumFromInt(@intFromEnum(style.flags.underline));
                render_cell.strikethrough = style.flags.strikethrough;
                render_cell.inverse = style.flags.inverse;
            }

            switch (raw.content_tag) {
                .bg_color_palette => {
                    render_cell.bg = .{ .palette = raw.content.color_palette };
                },
                .bg_color_rgb => {
                    const rgb = raw.content.color_rgb;
                    render_cell.bg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } };
                },
                else => {},
            }

            setCell(next, offset_x + x, offset_y + y, render_cell);
        }
    }
}

fn setCell(next: *CellBuffer, x: u16, y: u16, cell: Cell) void {
    if (x >= next.width or y >= next.height) return;
    next.get(x, y).* = cell;
}
