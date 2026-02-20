const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const pop = @import("pop");

const Cell = @import("render_types.zig").Cell;
const CursorInfo = @import("render_types.zig").CursorInfo;
const CellBuffer = @import("render_buffer.zig").CellBuffer;

const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");
const render_state_blit = @import("render_state_blit.zig");
const render_vx = @import("render_vx.zig");

/// Differential renderer that tracks state and only emits changed cells.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    current: CellBuffer,
    next: CellBuffer,
    vx: vaxis.Vaxis,
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        var vx = try vaxis.Vaxis.init(allocator, .{});
        try render_vx.initVaxisForSize(allocator, &vx, width, height);

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
        self.vx.screen.deinit(self.allocator);
        self.vx.screen_last.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        try self.current.resize(self.allocator, width, height);
        try self.next.resize(self.allocator, width, height);
        try render_vx.resizeVaxisForSize(self.allocator, &self.vx, width, height);
    }

    pub fn beginFrame(self: *Renderer) void {
        self.next.clear();
        self.vx.screen.clear();
    }

    pub fn invertCell(self: *Renderer, x: u16, y: u16) void {
        if (x >= self.next.width or y >= self.next.height) return;
        const cell = self.next.get(x, y);
        cell.inverse = !cell.inverse;
    }

    pub fn setCell(self: *Renderer, x: u16, y: u16, cell: Cell) void {
        if (x >= self.next.width or y >= self.next.height) return;
        self.next.get(x, y).* = cell;
    }

    pub fn screenWidth(self: *const Renderer) u16 {
        return self.next.width;
    }

    pub fn screenHeight(self: *const Renderer) u16 {
        return self.next.height;
    }

    /// Mutable access to a cell in the next-frame buffer.
    /// Returns null when coordinates are out of bounds.
    pub fn getCellMutable(self: *Renderer, x: u16, y: u16) ?*Cell {
        if (x >= self.next.width or y >= self.next.height) return null;
        return self.next.get(x, y);
    }

    pub fn drawRenderState(self: *Renderer, state: *const ghostty.RenderState, offset_x: u16, offset_y: u16, width: u16, height: u16) void {
        render_state_blit.drawRenderStateToBuffer(&self.next, state, offset_x, offset_y, width, height);
    }

    pub fn endFrame(self: *Renderer, force_full: bool, stdout: std.fs.File, cursor: CursorInfo) !void {
        render_vx.copyBufferToVaxisScreen(&self.next, &self.vx, self.frame_arena.allocator());
        try render_vx.renderFrame(&self.vx, stdout, cursor, force_full);
        _ = self.frame_arena.reset(.retain_capacity);
        std.mem.swap(CellBuffer, &self.current, &self.next);
    }

    pub fn invalidate(self: *Renderer) void {
        self.current.clear();
        self.vx.refresh = true;
    }

    pub fn drawSpriteOverlay(self: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16, pane_height: u16, sprite_content: []const u8, pokemon_config: pop.widgets.PokemonConfig) void {
        render_sprite.drawSpriteOverlay(self, Cell, pane_x, pane_y, pane_width, pane_height, sprite_content, pokemon_config);
    }
};

pub const drawRenderStateIntoWindow = vt_bridge.drawRenderState;
