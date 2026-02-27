const std = @import("std");
const style = @import("style.zig");
pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const Position = style.Position;

/// A single notification
pub const Notification = struct {
    message: []const u8,
    expires_at: i64,
    owned: bool, // true if message needs to be freed
    style: Style,

    pub fn isExpired(self: Notification) bool {
        return std.time.milliTimestamp() >= self.expires_at;
    }
};

/// Options for showing a notification
pub const NotifyOptions = struct {
    duration_ms: i64 = 3000,
    style: ?Style = null,
    owned: bool = false,
};

/// Notification manager - handles queue of notifications (non-blocking)
pub const NotificationManager = struct {
    allocator: std.mem.Allocator,
    current: ?Notification,
    queue: std.ArrayList(Notification),
    default_style: Style,
    default_duration_ms: i64,

    pub fn init(allocator: std.mem.Allocator) NotificationManager {
        return .{
            .allocator = allocator,
            .current = null,
            .queue = .empty,
            .default_style = .{},
            .default_duration_ms = 3000,
        };
    }

    /// Initialize with config
    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: anytype) NotificationManager {
        return .{
            .allocator = allocator,
            .current = null,
            .queue = .empty,
            .default_style = Style.fromConfig(cfg),
            .default_duration_ms = @intCast(cfg.duration_ms),
        };
    }

    pub fn deinit(self: *NotificationManager) void {
        // Free current notification if owned
        if (self.current) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        // Free queued notifications
        for (self.queue.items) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.queue.deinit(self.allocator);
    }

    /// Show a notification with default settings
    pub fn show(self: *NotificationManager, message: []const u8) void {
        self.showWithOptions(message, .{});
    }

    /// Show a notification for a specific duration
    pub fn showFor(self: *NotificationManager, message: []const u8, duration_ms: i64) void {
        self.showWithOptions(message, .{ .duration_ms = duration_ms });
    }

    /// Show a notification with full options
    pub fn showWithOptions(self: *NotificationManager, message: []const u8, opts: NotifyOptions) void {
        const notif = Notification{
            .message = message,
            .expires_at = std.time.milliTimestamp() + (if (opts.duration_ms > 0) opts.duration_ms else self.default_duration_ms),
            .owned = opts.owned,
            .style = opts.style orelse self.default_style,
        };

        // If no current notification, show immediately
        if (self.current == null) {
            self.current = notif;
        } else {
            // Queue it (might fail, that's ok)
            self.queue.append(self.allocator, notif) catch {};
        }
    }

    /// Update notification state - call each frame
    /// Returns true if display needs refresh
    pub fn update(self: *NotificationManager) bool {
        if (self.current) |notif| {
            if (notif.isExpired()) {
                // Clean up expired notification
                if (notif.owned) {
                    self.allocator.free(notif.message);
                }
                // Pop next from queue
                if (self.queue.items.len > 0) {
                    self.current = self.queue.orderedRemove(0);
                } else {
                    self.current = null;
                }
                return true; // needs refresh
            }
        }
        return false;
    }

    /// Check if there's an active notification
    pub fn hasActive(self: *NotificationManager) bool {
        return self.current != null;
    }

    /// Clear all notifications
    pub fn clear(self: *NotificationManager) void {
        if (self.current) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.current = null;

        for (self.queue.items) |notif| {
            if (notif.owned) {
                self.allocator.free(notif.message);
            }
        }
        self.queue.clearRetainingCapacity();
    }
};
