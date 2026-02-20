const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const pop = @import("pop");

const Cell = @import("render_types.zig").Cell;
const CursorInfo = @import("render_types.zig").CursorInfo;

const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");
const render_bridge = @import("render_bridge.zig");
const vaxis_cell = @import("vaxis_cell.zig");
const render_vx = @import("render_vx.zig");

/// Differential renderer that tracks state and only emits changed cells.
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    frame_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        var vx = try vaxis.Vaxis.init(allocator, .{});
        try render_vx.initVaxisForSize(allocator, &vx, width, height);

        return .{
            .allocator = allocator,
            .vx = vx,
            .frame_arena = .init(allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.frame_arena.deinit();
        self.vx.screen.deinit(self.allocator);
        self.vx.screen_last.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        try render_vx.resizeVaxisForSize(self.allocator, &self.vx, width, height);
    }

    pub fn beginFrame(self: *Renderer) void {
        self.vx.screen.clear();
    }

    pub fn invertCell(self: *Renderer, x: u16, y: u16) void {
        const cell = self.getCell(x, y) orelse return;
        var m = cell;
        m.inverse = !m.inverse;
        self.setCell(x, y, m);
    }

    pub fn setCell(self: *Renderer, x: u16, y: u16, cell: Cell) void {
        if (x >= self.vx.screen.width or y >= self.vx.screen.height) return;
        const vx_cell = render_bridge.cellToVaxis(cell, self.frame_arena.allocator());
        self.vx.screen.writeCell(x, y, vx_cell);
    }

    pub fn setVaxisCell(self: *Renderer, x: u16, y: u16, cell: vaxis.Cell) void {
        if (x >= self.vx.screen.width or y >= self.vx.screen.height) return;
        self.vx.screen.writeCell(x, y, cell);
    }

    pub fn getVaxisCell(self: *const Renderer, x: u16, y: u16) ?vaxis.Cell {
        if (x >= self.vx.screen.width or y >= self.vx.screen.height) return null;
        return self.vx.screen.readCell(x, y);
    }

    pub fn screenWidth(self: *const Renderer) u16 {
        return self.vx.screen.width;
    }

    pub fn screenHeight(self: *const Renderer) u16 {
        return self.vx.screen.height;
    }

    pub fn getCell(self: *const Renderer, x: u16, y: u16) ?Cell {
        if (x >= self.vx.screen.width or y >= self.vx.screen.height) return null;
        const vx_cell = self.vx.screen.readCell(x, y) orelse return null;
        return vaxis_cell.toRenderCell(vx_cell);
    }

    pub fn drawRenderState(self: *Renderer, state: *const ghostty.RenderState, offset_x: u16, offset_y: u16, width: u16, height: u16) void {
        const root = self.vx.window();
        const win = root.child(.{
            .x_off = @intCast(offset_x),
            .y_off = @intCast(offset_y),
            .width = width,
            .height = height,
        });
        vt_bridge.drawRenderState(win, state, width, height, self.frame_arena.allocator());
    }

    pub fn endFrame(self: *Renderer, force_full: bool, stdout: std.fs.File, cursor: CursorInfo) !void {
        try render_vx.renderFrame(&self.vx, stdout, cursor, force_full);
        _ = self.frame_arena.reset(.retain_capacity);
    }

    pub fn invalidate(self: *Renderer) void {
        self.vx.screen.clear();
        self.vx.refresh = true;
    }

    pub fn drawSpriteOverlay(self: *Renderer, pane_x: u16, pane_y: u16, pane_width: u16, pane_height: u16, sprite_content: []const u8, pokemon_config: pop.widgets.PokemonConfig) void {
        render_sprite.drawSpriteOverlay(self, pane_x, pane_y, pane_width, pane_height, sprite_content, pokemon_config);
    }
};

pub const drawRenderStateIntoWindow = vt_bridge.drawRenderState;
