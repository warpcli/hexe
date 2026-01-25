const std = @import("std");
const ghostty = @import("ghostty-vt");
const pagepkg = ghostty.page;
const colorpkg = ghostty.color;

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
        allocator.free(self.cells);
        const size = @as(usize, w) * @as(usize, h);
        self.cells = try allocator.alloc(Cell, size);
        @memset(self.cells, Cell{});
        self.width = w;
        self.height = h;
    }
};

// ESC character constant
const ESC: u8 = 0x1B;

/// Write a CSI sequence (ESC [) followed by the given suffix
fn writeCSI(output: *std.ArrayList(u8), allocator: std.mem.Allocator, suffix: []const u8) !void {
    try output.append(allocator, ESC);
    try output.append(allocator, '[');
    try output.appendSlice(allocator, suffix);
}

/// Write a CSI sequence with formatted parameters
fn writeCSIFmt(output: *std.ArrayList(u8), allocator: std.mem.Allocator, buf: []u8, comptime fmt: []const u8, args: anytype) !void {
    // Format first, THEN write - prevents partial sequences on format failure
    const formatted = std.fmt.bufPrint(buf, fmt, args) catch return;
    try output.append(allocator, ESC);
    try output.append(allocator, '[');
    try output.appendSlice(allocator, formatted);
}

/// Differential renderer that tracks state and only emits changed cells
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    current: CellBuffer, // Previous frame
    next: CellBuffer, // Next frame being built
    output: std.ArrayList(u8),

    // Tracked SGR state to avoid redundant escape sequences
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    current_fg: Color = .none,
    current_bg: Color = .none,
    current_bold: bool = false,
    current_italic: bool = false,
    current_faint: bool = false,
    current_underline: Cell.Underline = .none,
    current_strikethrough: bool = false,
    current_inverse: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        return .{
            .allocator = allocator,
            .current = try CellBuffer.init(allocator, width, height),
            .next = try CellBuffer.init(allocator, width, height),
            .output = .empty,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.current.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.output.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        try self.current.resize(self.allocator, width, height);
        try self.next.resize(self.allocator, width, height);
    }

    /// Begin a new frame - clear the next buffer
    pub fn beginFrame(self: *Renderer) void {
        self.next.clear();
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
                    self.setCell(offset_x + x, offset_y + y, render_cell);
                    continue;
                }

                if (raw.wide == .spacer_head) {
                    // Spacer cell at end-of-line for a wide character wrap.
                    // Render as a normal blank so we still clear any prior
                    // screen contents in that column.
                    render_cell.char = ' ';
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

    /// End frame and render differences to output buffer
    /// Returns the output to write to terminal
    pub fn endFrame(self: *Renderer, force_full: bool) ![]const u8 {
        self.output.clearRetainingCapacity();

        const width = self.next.width;
        const height = self.next.height;

        // Fast path: if nothing changed, emit nothing.
        if (!force_full) {
            var changed = false;
            for (0..height) |yi| {
                const y: u16 = @intCast(yi);
                for (0..width) |xi| {
                    const x: u16 = @intCast(xi);
                    if (!self.current.getConst(x, y).eql(self.next.getConst(x, y))) {
                        changed = true;
                        break;
                    }
                }
                if (changed) break;
            }

            if (!changed) {
                std.mem.swap(CellBuffer, &self.current, &self.next);
                return self.output.items;
            }
        }

        // Pre-allocate enough space for worst case (every cell changes with full color sequences)
        // Estimate: ~30 bytes per cell (position + color + char)
        const estimated_size = @as(usize, width) * @as(usize, height) * 30;
        try self.output.ensureTotalCapacity(self.allocator, estimated_size);

        // Begin synchronized update, hide cursor, reset all attributes.
        // The SGR reset ensures we start from a known state.
        try writeCSI(&self.output, self.allocator, "?2026h"); // begin sync
        try writeCSI(&self.output, self.allocator, "?25l"); // hide cursor
        try writeCSI(&self.output, self.allocator, "0m"); // reset attributes
        if (force_full) {
            // Ensure the outer terminal fully clears any stale backgrounds.
            try writeCSI(&self.output, self.allocator, "H");
            try writeCSI(&self.output, self.allocator, "2J");
        }
        self.current_fg = .none;
        self.current_bg = .none;
        self.current_bold = false;
        self.current_italic = false;
        self.current_faint = false;
        self.current_underline = .none;
        self.current_strikethrough = false;
        self.current_inverse = false;

        // Use a fixed buffer for building escape sequences to ensure atomic writes
        var seq_buf: [64]u8 = undefined;

        for (0..height) |yi| {
            const y: u16 = @intCast(yi);

            var start_x: usize = 0;
            if (!force_full) {
                // Find the first differing cell in this row.
                start_x = width;
                for (0..width) |xi| {
                    const old = self.current.getConst(@intCast(xi), y);
                    const new = self.next.getConst(@intCast(xi), y);
                    if (!old.eql(new)) {
                        start_x = xi;
                        break;
                    }
                }

                if (start_x == width) {
                    // No changes in this row.
                    continue;
                }
            }

            // Position cursor at start of the row.
            try writeCSIFmt(&self.output, self.allocator, &seq_buf, "{d};1H", .{y + 1});

            var cursor_x: usize = 0;

            // Skip to the first changed cell.
            if (start_x > 0) {
                try writeCSIFmt(&self.output, self.allocator, &seq_buf, "{d}C", .{start_x});
                cursor_x = start_x;
            }

            var pending_skip: usize = 0;
            for (start_x..width) |xi| {
                const old = self.current.getConst(@intCast(xi), y);
                const new = self.next.getConst(@intCast(xi), y);

                if (!force_full and old.eql(new)) {
                    pending_skip += 1;
                    continue;
                }

                if (pending_skip > 0) {
                    try writeCSIFmt(&self.output, self.allocator, &seq_buf, "{d}C", .{pending_skip});
                    cursor_x += pending_skip;
                    pending_skip = 0;
                }

                // Wide-character spacer tail: advance cursor but don't overwrite.
                if (new.char == 0) {
                    try writeCSI(&self.output, self.allocator, "1C");
                    cursor_x += 1;
                    continue;
                }

                try self.emitStyleChanges(&seq_buf, new);
                try self.emitChar(new.char);
                cursor_x += 1;
            }

            // If the remainder of the row is a uniform blank run, explicitly
            // clear it via EL (erase to end of line). This prevents stale
            // backgrounds/attrs from previous content from persisting when the
            // model is "blank" but we didn't overwrite every trailing cell.
            if (!force_full and cursor_x < width) {
                const base = self.next.getConst(@intCast(cursor_x), y);

                // Only do this optimization for trailing blanks.
                if (base.char == ' ') {
                    var tail_uniform = true;
                    for (cursor_x..width) |xi| {
                        const cell = self.next.getConst(@intCast(xi), y);
                        if (!cell.eql(base)) {
                            tail_uniform = false;
                            break;
                        }
                    }

                    if (tail_uniform) {
                        // Make sure the SGR state matches the blank tail.
                        try self.emitStyleChanges(&seq_buf, base);
                        try writeCSI(&self.output, self.allocator, "K");
                    }
                }
            }
        }

        // Reset attributes and end synchronized update
        try writeCSI(&self.output, self.allocator, "0m");
        try writeCSI(&self.output, self.allocator, "?2026l"); // end sync - display now

        // Swap buffers
        std.mem.swap(CellBuffer, &self.current, &self.next);

        return self.output.items;
    }

    fn emitStyleChanges(self: *Renderer, seq_buf: *[64]u8, cell: Cell) !void {
        // Check if we need a full reset
        const need_reset = (self.current_bold and !cell.bold) or
            (self.current_italic and !cell.italic) or
            (self.current_faint and !cell.faint) or
            (self.current_underline != .none and cell.underline == .none) or
            (self.current_strikethrough and !cell.strikethrough) or
            (self.current_inverse and !cell.inverse);

        if (need_reset) {
            try writeCSI(&self.output, self.allocator, "0m");
            self.current_fg = .none;
            self.current_bg = .none;
            self.current_bold = false;
            self.current_italic = false;
            self.current_faint = false;
            self.current_underline = .none;
            self.current_strikethrough = false;
            self.current_inverse = false;
        }

        // Emit attribute changes
        if (cell.bold and !self.current_bold) {
            try writeCSI(&self.output, self.allocator, "1m");
            self.current_bold = true;
        }

        if (cell.faint and !self.current_faint) {
            try writeCSI(&self.output, self.allocator, "2m");
            self.current_faint = true;
        }

        if (cell.italic and !self.current_italic) {
            try writeCSI(&self.output, self.allocator, "3m");
            self.current_italic = true;
        }

        if (cell.underline != self.current_underline) {
            switch (cell.underline) {
                .none => {}, // handled by reset
                .single => try writeCSI(&self.output, self.allocator, "4m"),
                .double => try writeCSI(&self.output, self.allocator, "4:2m"),
                .curly => try writeCSI(&self.output, self.allocator, "4:3m"),
                .dotted => try writeCSI(&self.output, self.allocator, "4:4m"),
                .dashed => try writeCSI(&self.output, self.allocator, "4:5m"),
            }
            self.current_underline = cell.underline;
        }

        if (cell.inverse and !self.current_inverse) {
            try writeCSI(&self.output, self.allocator, "7m");
            self.current_inverse = true;
        }

        if (cell.strikethrough and !self.current_strikethrough) {
            try writeCSI(&self.output, self.allocator, "9m");
            self.current_strikethrough = true;
        }

        // Emit foreground color change
        if (!cell.fg.eql(self.current_fg)) {
            switch (cell.fg) {
                .none => try writeCSI(&self.output, self.allocator, "39m"),
                .palette => |idx| try writeCSIFmt(&self.output, self.allocator, seq_buf, "38;5;{d}m", .{idx}),
                .rgb => |rgb| try writeCSIFmt(&self.output, self.allocator, seq_buf, "38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
            }
            self.current_fg = cell.fg;
        }

        // Emit background color change
        if (!cell.bg.eql(self.current_bg)) {
            switch (cell.bg) {
                .none => try writeCSI(&self.output, self.allocator, "49m"),
                .palette => |idx| try writeCSIFmt(&self.output, self.allocator, seq_buf, "48;5;{d}m", .{idx}),
                .rgb => |rgb| try writeCSIFmt(&self.output, self.allocator, seq_buf, "48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
            }
            self.current_bg = cell.bg;
        }
    }

    fn emitChar(self: *Renderer, char: u21) !void {
        if (char == 0) return;
        if (char < 128) {
            try self.output.append(self.allocator, @intCast(char));
        } else {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(char, &buf) catch {
                // Invalid codepoint, emit replacement character
                try self.output.appendSlice(self.allocator, "\xef\xbf\xbd"); // U+FFFD
                return;
            };
            try self.output.appendSlice(self.allocator, buf[0..len]);
        }
    }

    /// Reset SGR state tracking (call after full screen clear)
    pub fn resetState(self: *Renderer) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.current_fg = .none;
        self.current_bg = .none;
        self.current_bold = false;
        self.current_italic = false;
        self.current_faint = false;
        self.current_underline = .none;
        self.current_strikethrough = false;
        self.current_inverse = false;
    }

    /// Force full redraw on next frame
    pub fn invalidate(self: *Renderer) void {
        self.current.clear();
        self.resetState();
    }
};
