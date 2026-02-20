const std = @import("std");
const vaxis = @import("vaxis");
const ghostty = @import("ghostty-vt");
const pop = @import("pop");
const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");
const render_bridge = @import("render_bridge.zig");
const render_types = @import("render_types.zig");
const render_buffer = @import("render_buffer.zig");
const render_state_blit = @import("render_state_blit.zig");

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
        render_state_blit.drawRenderStateToBuffer(&self.next, state, offset_x, offset_y, width, height);
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
