const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const pop = @import("pop");
const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");
const render_types = @import("render_types.zig");
const render_buffer = @import("render_buffer.zig");
const render_state_blit = @import("render_state_blit.zig");
const render_vx = @import("render_vx.zig");

pub const Cell = render_types.Cell;
pub const Color = render_types.Color;
pub const CursorInfo = render_types.CursorInfo;
pub const CellBuffer = render_buffer.CellBuffer;

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
        // Free vaxis screen resources directly (skip terminal reset since we
        // handle that ourselves during shutdown).
        self.vx.screen.deinit(self.allocator);
        self.vx.screen_last.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, width: u16, height: u16) !void {
        try self.current.resize(self.allocator, width, height);
        try self.next.resize(self.allocator, width, height);
        try render_vx.resizeVaxisForSize(self.allocator, &self.vx, width, height);
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
        render_state_blit.drawRenderStateToBuffer(&self.next, state, offset_x, offset_y, width, height);
    }

    /// End frame: copy CellBuffer to vaxis screen and render via libvaxis.
    /// Takes cursor info and the output file to write to.
    pub fn endFrame(self: *Renderer, force_full: bool, stdout: std.fs.File, cursor: CursorInfo) !void {
        render_vx.copyBufferToVaxisScreen(&self.next, &self.vx, self.frame_arena.allocator());
        try render_vx.renderFrame(&self.vx, stdout, cursor, force_full);

        // Free frame arena (grapheme strings are no longer needed after render)
        _ = self.frame_arena.reset(.retain_capacity);

        // Swap old CellBuffers so callers that read `current` see last frame
        std.mem.swap(CellBuffer, &self.current, &self.next);
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
