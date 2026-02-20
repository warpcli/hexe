const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const pagepkg = ghostty.page;
const colorpkg = ghostty.color;
const pop = @import("pop");
const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");
const render_bridge = @import("render_bridge.zig");

/// Represents a single rendered cell with all its attributes
pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .none,
    bg: Color = .none,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: Underline = .none,
    strikethrough: bool = false,
    inverse: bool = false,
    is_wide_spacer: bool = false, // True if this cell is a spacer for a wide character
    is_wide_char: bool = false, // True if this character is wide (takes 2 columns)

    pub const Underline = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.bold == other.bold and
            self.italic == other.italic and
            self.faint == other.faint and
            self.underline == other.underline and
            self.strikethrough == other.strikethrough and
            self.inverse == other.inverse;
    }
};

/// Color representation
pub const Color = union(enum) {
    none,
    palette: u8,
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn eql(self: RGB, other: RGB) bool {
            return self.r == other.r and self.g == other.g and self.b == other.b;
        }
    };

    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .none => other == .none,
            .palette => |p| other == .palette and other.palette == p,
            .rgb => |rgb| other == .rgb and rgb.eql(other.rgb),
        };
    }

    /// Convert from ghostty style color
    pub fn fromStyleColor(c: ghostty.Style.Color) Color {
        return switch (c) {
            .none => .none,
            .palette => |p| .{ .palette = p },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        };
    }
};

/// Double-buffered cell grid for differential rendering
pub const CellBuffer = struct {
    cells: []Cell,
    width: u16,
    height: u16,

    pub fn init(allocator: std.mem.Allocator, w: u16, h: u16) !CellBuffer {
        const size = @as(usize, w) * @as(usize, h);
        const cells = try allocator.alloc(Cell, size);
        @memset(cells, Cell{});
        return .{
            .cells = cells,
            .width = w,
            .height = h,
        };
    }

    pub fn deinit(self: *CellBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }

    pub fn get(self: *CellBuffer, x: u16, y: u16) *Cell {
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        return &self.cells[idx];
    }

    pub fn getConst(self: *const CellBuffer, x: u16, y: u16) Cell {
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        return self.cells[idx];
    }

    pub fn clear(self: *CellBuffer) void {
        @memset(self.cells, Cell{});
    }

    pub fn resize(self: *CellBuffer, allocator: std.mem.Allocator, w: u16, h: u16) !void {
        if (w == self.width and h == self.height) return;

        // Allocate new buffer
        const new_size = @as(usize, w) * @as(usize, h);
        const new_cells = try allocator.alloc(Cell, new_size);
        @memset(new_cells, Cell{});

        // Preserve overlapping content from old buffer
        const copy_width = @min(w, self.width);
        const copy_height = @min(h, self.height);

        var y: u16 = 0;
        while (y < copy_height) : (y += 1) {
            const old_row_start = @as(usize, y) * @as(usize, self.width);
            const new_row_start = @as(usize, y) * @as(usize, w);
            const copy_len = @as(usize, copy_width);

            // Copy row from old to new buffer
            @memcpy(new_cells[new_row_start..][0..copy_len], self.cells[old_row_start..][0..copy_len]);
        }

        // Free old buffer and update to new
        allocator.free(self.cells);
        self.cells = new_cells;
        self.width = w;
        self.height = h;
    }
};

/// Cursor information for rendering
pub const CursorInfo = struct {
    x: u16 = 0,
    y: u16 = 0,
    style: u8 = 0,
    visible: bool = true,
};

/// Differential renderer that tracks state and only emits changed cells.
/// Internally uses libvaxis for terminal output while maintaining a CellBuffer
/// for backward compatibility with existing UI code.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    current: CellBuffer, // Previous frame (used by callers that read cells)
    next: CellBuffer, // Next frame being built
    vx: vaxis.Vaxis, // libvaxis rendering engine
    /// Frame-scoped arena for temporary grapheme UTF-8 strings.
    /// Allocated during copyToVaxisScreen, freed after vx.render() completes.
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        var vx = try vaxis.Vaxis.init(allocator, .{});
        // Resize vaxis screens to match initial terminal size.
        // We do this manually to avoid needing a tty writer at init time.
        if (width > 0 and height > 0) {
            vx.screen = try vaxis.Screen.init(allocator, .{
                .rows = height,
                .cols = width,
                .x_pixel = 0,
                .y_pixel = 0,
            });
            vx.screen_last.deinit(allocator);
            vx.screen_last = try vaxis.AllocatingScreen.init(allocator, width, height);
        }

        return .{
            .allocator = allocator,
            .current = try CellBuffer.init(allocator, width, height),
            .next = try CellBuffer.init(allocator, width, height),
            .vx = vx,
            .frame_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.current.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.frame_arena.deinit();
        // Free vaxis screen resources directly (skip terminal reset since we
        // handle that ourselves during shutdown).
        self.vx.screen.deinit(self.allocator);
        self.vx.screen_last.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        try self.current.resize(self.allocator, width, height);
        try self.next.resize(self.allocator, width, height);

        // Resize vaxis screens to match new terminal dimensions.
        self.vx.screen.deinit(self.allocator);
        self.vx.screen = try vaxis.Screen.init(self.allocator, .{
            .rows = height,
            .cols = width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        self.vx.screen_last.deinit(self.allocator);
        self.vx.screen_last = try vaxis.AllocatingScreen.init(self.allocator, width, height);
    }

    /// Begin a new frame - clear the next buffer and vaxis screen
    pub fn beginFrame(self: *Renderer) void {
        self.next.clear();
        self.vx.screen.clear();
    }

    /// Invert a cell in the next-frame buffer.
    ///
    /// This is used for mux-side selection highlighting overlays.
    pub fn invertCell(self: *Renderer, x: u16, y: u16) void {
        if (x >= self.next.width or y >= self.next.height) return;
        const cell = self.next.get(x, y);
        cell.inverse = !cell.inverse;
    }

    /// Set a cell in the next frame buffer
    pub fn setCell(self: *Renderer, x: u16, y: u16, cell: Cell) void {
        // Strict bounds checking - prevent any out-of-bounds writes
        // This is critical when rendering from large scrollback states
        if (x >= self.next.width or y >= self.next.height) return;
        self.next.get(x, y).* = cell;
    }

    /// Draw a pane's viewport content into the frame buffer at the given offset.
    ///
    /// This renders from ghostty's `RenderState` snapshot, which is safe to read
    /// even when the terminal is actively scrolling or updating pages.
    pub fn drawRenderState(self: *Renderer, state: *const ghostty.RenderState, offset_x: u16, offset_y: u16, width: u16, height: u16) void {
        // Validate RenderState dimensions to prevent corruption from large scrollback
        // Ghostty's state.rows/cols can become very large when scrollback is huge
        // We must clamp to reasonable values to avoid buffer overruns
        const MAX_REASONABLE_ROWS: usize = 10000;
        const MAX_REASONABLE_COLS: usize = 1000;

        const row_slice = state.row_data.slice();

        // Clamp state dimensions to reasonable maximums to prevent corruption
        const safe_state_rows = @min(@as(usize, state.rows), MAX_REASONABLE_ROWS);
        const safe_state_cols = @min(@as(usize, state.cols), MAX_REASONABLE_COLS);

        // Also clamp to requested dimensions
        const rows = @min(@as(usize, height), safe_state_rows);
        const cols = @min(@as(usize, width), safe_state_cols);

        // Validate we're not reading beyond row_data bounds
        const available_rows = @min(rows, row_slice.len);
        if (available_rows == 0) return;

        const row_cells = row_slice.items(.cells);

        // Calculate maximum safe write position in the renderer's cell buffer
        const max_write_x = self.next.width;
        const max_write_y = self.next.height;

        for (0..available_rows) |yi| {
            const y: u16 = @intCast(yi);

            // Skip writing if we're beyond the renderer's Y bounds
            if (offset_y + y >= max_write_y) break;

            const cells_slice = row_cells[yi].slice();
            const raw_cells = cells_slice.items(.raw);
            const styles = cells_slice.items(.style);

            for (0..cols) |xi| {
                const x: u16 = @intCast(xi);

                // Skip writing if we're beyond the renderer's X bounds
                if (offset_x + x >= max_write_x) break;

                const raw = raw_cells[xi];

                var render_cell = Cell{};
                render_cell.char = raw.codepoint();

                // Ghostty uses codepoint 0 to represent an empty cell.
                // We render that as a space so it actively clears old content.
                if (render_cell.char == 0) {
                    render_cell.char = ' ';
                }

                // Filter out control characters (including ESC).
                if (render_cell.char < 32 or render_cell.char == 127) {
                    render_cell.char = ' ';
                }

                // Ghostty uses spacer cells for wide characters.
                // These should not be rendered at all, since the wide character
                // already consumes their terminal column(s).
                if (raw.wide == .spacer_tail) {
                    // Tail cell of a wide character: do not overwrite.
                    // We advance the cursor during rendering.
                    render_cell.char = 0;
                    render_cell.is_wide_spacer = true;
                    self.setCell(offset_x + x, offset_y + y, render_cell);
                    continue;
                }

                if (raw.wide == .spacer_head) {
                    // Spacer cell at end-of-line for a wide character wrap.
                    // Render as a normal blank so we still clear any prior
                    // screen contents in that column.
                    render_cell.char = ' ';
                }

                // Mark wide characters (emoji, CJK, etc.)
                if (raw.wide == .wide) {
                    render_cell.is_wide_char = true;
                }

                // RenderState's per-cell `style` is only valid when `style_id != 0`.
                // For default-style cells, the contents of `styles[xi]` are undefined.
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

                // Background-only cells can exist with default style.
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

                self.setCell(offset_x + x, offset_y + y, render_cell);
            }
        }
    }

    /// Copy the CellBuffer contents to the vaxis screen for rendering.
    /// Translates hexa Cell -> vaxis Cell types, using the frame arena for
    /// non-ASCII grapheme string storage.
    fn copyToVaxisScreen(self: *Renderer) void {
        const width = self.next.width;
        const height = self.next.height;
        const arena = self.frame_arena.allocator();

        for (0..height) |yi| {
            const y: u16 = @intCast(yi);
            for (0..width) |xi| {
                const x: u16 = @intCast(xi);
                const cell = self.next.getConst(x, y);

                // Convert hexa Cell -> vaxis Cell
                const vx_cell = render_bridge.cellToVaxis(cell, arena);
                self.vx.screen.writeCell(x, y, vx_cell);
            }
        }
    }

    /// End frame: copy CellBuffer to vaxis screen and render via libvaxis.
    /// Takes cursor info and the output file to write to.
    pub fn endFrame(self: *Renderer, force_full: bool, stdout: std.fs.File, cursor: CursorInfo) !void {
        // Copy the CellBuffer to the vaxis screen
        self.copyToVaxisScreen();

        // Set cursor state on the vaxis screen
        self.vx.screen.cursor_vis = cursor.visible;
        if (cursor.visible) {
            self.vx.screen.cursor = .{ .col = cursor.x, .row = cursor.y };
            self.vx.screen.cursor_shape = render_bridge.mapCursorShape(cursor.style);
        }

        if (force_full) {
            self.vx.refresh = true;
        }

        // Render via vaxis to stdout
        var write_buf: [8192]u8 = undefined;
        var writer = stdout.writer(&write_buf);
        try self.vx.render(&writer.interface);
        writer.interface.flush() catch {};

        // Free frame arena (grapheme strings are no longer needed after render)
        _ = self.frame_arena.reset(.retain_capacity);

        // Swap old CellBuffers so callers that read `current` see last frame
        std.mem.swap(CellBuffer, &self.current, &self.next);

        // Clear force-refresh after rendering
        self.vx.refresh = false;
    }

    /// Force full redraw on next frame
    pub fn invalidate(self: *Renderer) void {
        self.current.clear();
        self.vx.refresh = true;
    }

    /// Draw a sprite overlay centered in the given pane bounds
    pub fn drawSpriteOverlay(self: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16, pane_height: u16, sprite_content: []const u8, pokemon_config: pop.widgets.PokemonConfig) void {
        render_sprite.drawSpriteOverlay(self, Cell, pane_x, pane_y, pane_width, pane_height, sprite_content, pokemon_config);
    }
};
