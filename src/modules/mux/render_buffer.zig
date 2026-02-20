const std = @import("std");
const Cell = @import("render_types.zig").Cell;

/// Double-buffered cell grid for differential rendering.
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

        const new_size = @as(usize, w) * @as(usize, h);
        const new_cells = try allocator.alloc(Cell, new_size);
        @memset(new_cells, Cell{});

        const copy_width = @min(w, self.width);
        const copy_height = @min(h, self.height);

        var y: u16 = 0;
        while (y < copy_height) : (y += 1) {
            const old_row_start = @as(usize, y) * @as(usize, self.width);
            const new_row_start = @as(usize, y) * @as(usize, w);
            const copy_len = @as(usize, copy_width);
            @memcpy(new_cells[new_row_start..][0..copy_len], self.cells[old_row_start..][0..copy_len]);
        }

        allocator.free(self.cells);
        self.cells = new_cells;
        self.width = w;
        self.height = h;
    }
};
