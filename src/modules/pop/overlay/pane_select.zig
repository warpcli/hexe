const std = @import("std");

/// Pane label for select mode
pub const PaneLabel = struct {
    uuid: [32]u8,
    label: u8, // '1'-'9', 'a'-'z'
    x: u16, // pane top-left x
    y: u16, // pane top-left y
    width: u16,
    height: u16,
};

/// Pane select/swap mode state
pub const PaneSelectState = struct {
    allocator: std.mem.Allocator,
    active: bool,
    swap_mode: bool, // true = swap with focused, false = just focus
    labels: std.ArrayList(PaneLabel),

    pub fn init(allocator: std.mem.Allocator) PaneSelectState {
        return .{
            .allocator = allocator,
            .active = false,
            .swap_mode = false,
            .labels = .empty,
        };
    }

    pub fn deinit(self: *PaneSelectState) void {
        self.labels.deinit(self.allocator);
    }

    /// Enter pane select mode
    pub fn enter(self: *PaneSelectState, swap: bool) void {
        self.active = true;
        self.swap_mode = swap;
        self.labels.clearRetainingCapacity();
    }

    /// Exit pane select mode
    pub fn exit(self: *PaneSelectState) void {
        self.active = false;
        self.labels.clearRetainingCapacity();
    }

    /// Add a pane label
    pub fn addLabel(self: *PaneSelectState, uuid: [32]u8, label: u8, x: u16, y: u16, w: u16, h: u16) void {
        self.labels.append(self.allocator, .{
            .uuid = uuid,
            .label = label,
            .x = x,
            .y = y,
            .width = w,
            .height = h,
        }) catch {};
    }

    /// Find pane UUID by label character
    pub fn findByLabel(self: *const PaneSelectState, label: u8) ?[32]u8 {
        for (self.labels.items) |pl| {
            if (pl.label == label) return pl.uuid;
        }
        return null;
    }

    /// Get all labels for rendering
    pub fn getLabels(self: *const PaneSelectState) []const PaneLabel {
        return self.labels.items;
    }

    /// Check if mode is active
    pub fn isActive(self: *const PaneSelectState) bool {
        return self.active;
    }

    /// Check if in swap mode (vs focus mode)
    pub fn isSwapMode(self: *const PaneSelectState) bool {
        return self.swap_mode;
    }
};

/// Generate label character for pane index (1-9, then a-z)
pub fn labelForIndex(idx: usize) ?u8 {
    if (idx < 9) {
        return '1' + @as(u8, @intCast(idx));
    } else if (idx < 9 + 26) {
        return 'a' + @as(u8, @intCast(idx - 9));
    }
    return null;
}

/// Parse label character back to index
pub fn indexFromLabel(label: u8) ?usize {
    if (label >= '1' and label <= '9') {
        return label - '1';
    } else if (label >= 'a' and label <= 'z') {
        return 9 + (label - 'a');
    }
    return null;
}
