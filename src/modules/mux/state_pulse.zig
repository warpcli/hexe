const std = @import("std");

const state_mod = @import("state.zig");
const State = state_mod.State;
const PaneBounds = state_mod.PaneBounds;
const winpulse_mod = @import("winpulse.zig");

/// Start winpulse animation for the currently focused pane.
pub fn startPulse(self: *State) void {
    if (!self.config.winpulse_enabled) return;

    const PaneInfo = struct {
        uuid: [32]u8,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    };

    const pane_info: ?PaneInfo = blk: {
        if (self.active_floating) |idx| {
            if (idx < self.floats.items.len) {
                const pane = self.floats.items[idx];
                break :blk PaneInfo{
                    .uuid = pane.uuid,
                    .x = pane.x,
                    .y = pane.y,
                    .width = pane.width,
                    .height = pane.height,
                };
            }
        }
        if (self.currentLayout().getFocusedPane()) |pane| {
            break :blk PaneInfo{
                .uuid = pane.uuid,
                .x = pane.x,
                .y = pane.y,
                .width = pane.width,
                .height = pane.height,
            };
        }
        break :blk null;
    };

    if (pane_info) |info| {
        stopPulse(self);

        self.pulse_start_ms = std.time.milliTimestamp();
        self.pulse_pane_uuid = info.uuid;
        self.pulse_pane_bounds = PaneBounds{
            .x = info.x,
            .y = info.y,
            .width = info.width,
            .height = info.height,
        };

        const size = @as(usize, info.width) * @as(usize, info.height);
        const saved = self.allocator.alloc(winpulse_mod.SavedCell, size) catch {
            return;
        };

        var idx: usize = 0;
        var row: u16 = 0;
        while (row < info.height) : (row += 1) {
            var col: u16 = 0;
            while (col < info.width) : (col += 1) {
                const cell = self.renderer.next.getConst(info.x + col, info.y + row);
                saved[idx] = winpulse_mod.SavedCell{
                    .fg = cell.fg,
                    .bg = cell.bg,
                };
                idx += 1;
            }
        }
        self.pulse_saved_colors = saved;
        self.needs_render = true;
    }
}

/// Stop winpulse animation and restore original colors.
pub fn stopPulse(self: *State) void {
    if (self.pulse_saved_colors) |saved| {
        self.allocator.free(saved);
        self.pulse_saved_colors = null;
    }
    self.pulse_start_ms = 0;
    self.pulse_pane_uuid = null;
    self.pulse_pane_bounds = null;
}
