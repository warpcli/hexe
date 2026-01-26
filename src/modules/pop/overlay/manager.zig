const std = @import("std");
const types = @import("types.zig");
const keycast = @import("keycast.zig");
const pane_select = @import("pane_select.zig");

pub const Overlay = types.Overlay;
pub const Position = types.Position;
pub const Corner = types.Corner;

/// Manages all overlay state
pub const OverlayManager = struct {
    allocator: std.mem.Allocator,

    /// Generic overlays (info, persistent)
    overlays: std.ArrayList(Overlay),

    /// Pane select/swap mode
    pane_select: pane_select.PaneSelectState,

    /// Keycast display
    keycast: keycast.KeycastState,

    /// Resize info overlay (shown during float resize)
    resize_info_active: bool,
    resize_info_pane_uuid: [32]u8,
    resize_info_width: u16,
    resize_info_height: u16,
    resize_info_x: u16,
    resize_info_y: u16,

    pub fn init(allocator: std.mem.Allocator) OverlayManager {
        return .{
            .allocator = allocator,
            .overlays = .empty,
            .pane_select = pane_select.PaneSelectState.init(allocator),
            .keycast = keycast.KeycastState.init(),
            .resize_info_active = false,
            .resize_info_pane_uuid = undefined,
            .resize_info_width = 0,
            .resize_info_height = 0,
            .resize_info_x = 0,
            .resize_info_y = 0,
        };
    }

    pub fn deinit(self: *OverlayManager) void {
        for (self.overlays.items) |overlay| {
            if (overlay.owned) {
                self.allocator.free(overlay.text);
            }
        }
        self.overlays.deinit(self.allocator);
        self.pane_select.deinit();
    }

    /// Update overlay state - call each frame.
    /// Returns true if display needs refresh.
    pub fn update(self: *OverlayManager) bool {
        const now = std.time.milliTimestamp();
        var changed = false;

        // Expire generic overlays
        var i: usize = 0;
        while (i < self.overlays.items.len) {
            const overlay = self.overlays.items[i];
            if (overlay.expires_at > 0 and now >= overlay.expires_at) {
                if (overlay.owned) {
                    self.allocator.free(overlay.text);
                }
                _ = self.overlays.orderedRemove(i);
                changed = true;
                continue;
            }
            i += 1;
        }

        // Update keycast
        if (self.keycast.update()) {
            changed = true;
        }

        return changed;
    }

    /// Check if any modal overlay is active (captures input)
    pub fn isModal(self: *const OverlayManager) bool {
        return self.pane_select.isActive();
    }

    /// Check if dimming should be applied
    pub fn shouldDim(self: *const OverlayManager) bool {
        return self.pane_select.isActive();
    }

    /// Show an info overlay that auto-expires
    pub fn showInfo(
        self: *OverlayManager,
        text: []const u8,
        position: Position,
        duration_ms: i64,
    ) void {
        self.overlays.append(self.allocator, .{
            .kind = .info,
            .position = position,
            .text = text,
            .owned = false,
            .expires_at = std.time.milliTimestamp() + duration_ms,
            .fg = 0,
            .bg = 3,
            .bold = true,
            .padding_x = 1,
            .padding_y = 0,
        }) catch {};
    }

    // =========================================================================
    // Resize info
    // =========================================================================

    pub fn showResizeInfo(self: *OverlayManager, uuid: [32]u8, w: u16, h: u16, x: u16, y: u16) void {
        self.resize_info_active = true;
        self.resize_info_pane_uuid = uuid;
        self.resize_info_width = w;
        self.resize_info_height = h;
        self.resize_info_x = x;
        self.resize_info_y = y;
    }

    pub fn hideResizeInfo(self: *OverlayManager) void {
        self.resize_info_active = false;
    }

    pub fn isResizeInfoActive(self: *const OverlayManager) bool {
        return self.resize_info_active;
    }

    // =========================================================================
    // Pane select mode
    // =========================================================================

    pub fn enterPaneSelectMode(self: *OverlayManager, swap: bool) void {
        self.pane_select.enter(swap);
    }

    pub fn exitPaneSelectMode(self: *OverlayManager) void {
        self.pane_select.exit();
    }

    pub fn addPaneLabel(self: *OverlayManager, uuid: [32]u8, label: u8, x: u16, y: u16, w: u16, h: u16) void {
        self.pane_select.addLabel(uuid, label, x, y, w, h);
    }

    pub fn findPaneByLabel(self: *const OverlayManager, label: u8) ?[32]u8 {
        return self.pane_select.findByLabel(label);
    }

    pub fn isPaneSelectActive(self: *const OverlayManager) bool {
        return self.pane_select.isActive();
    }

    pub fn isPaneSelectSwapMode(self: *const OverlayManager) bool {
        return self.pane_select.isSwapMode();
    }

    // =========================================================================
    // Keycast
    // =========================================================================

    pub fn toggleKeycast(self: *OverlayManager) void {
        self.keycast.toggle();
    }

    pub fn recordKeypress(self: *OverlayManager, text: []const u8) void {
        self.keycast.record(text);
    }

    pub fn isKeycastEnabled(self: *const OverlayManager) bool {
        return self.keycast.enabled;
    }

    // =========================================================================
    // Utility
    // =========================================================================

    /// Check if there's anything to render
    pub fn hasContent(self: *const OverlayManager) bool {
        return self.overlays.items.len > 0 or
            self.pane_select.isActive() or
            self.resize_info_active or
            self.keycast.hasContent();
    }

    /// Get generic overlays for rendering
    pub fn getOverlays(self: *const OverlayManager) []const Overlay {
        return self.overlays.items;
    }
};
