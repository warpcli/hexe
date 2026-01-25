const std = @import("std");
const render = @import("render.zig");
const Renderer = render.Renderer;
const Color = render.Color;

/// Horizontal alignment of the notification
pub const Align = enum {
    left,
    center,
    right,
};

/// Style configuration for notifications
pub const Style = struct {
    fg: Color = .{ .palette = 0 }, // black text
    bg: Color = .{ .palette = 1 }, // red background (default, overridden by config)
    bold: bool = true,
    padding_x: u16 = 1, // horizontal padding inside box
    padding_y: u16 = 0, // vertical padding inside box
    offset: u16 = 1, // MUX: cells down from top, PANE: cells up from bottom
    alignment: Align = .center, // horizontal alignment

    /// Create style from config
    pub fn fromConfig(cfg: anytype) Style {
        // Parse align from string
        const align_val: Align = if (std.mem.eql(u8, cfg.alignment, "left")) .left else if (std.mem.eql(u8, cfg.alignment, "right")) .right else .center;

        return .{
            .fg = .{ .palette = cfg.fg },
            .bg = .{ .palette = cfg.bg },
            .bold = cfg.bold,
            .padding_x = cfg.padding_x,
            .padding_y = cfg.padding_y,
            .offset = cfg.offset,
            .alignment = align_val,
        };
    }
};

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

/// Notification manager - handles queue of notifications
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

    /// Initialize with pop.NotificationStyle config
    pub fn initWithPopConfig(allocator: std.mem.Allocator, cfg: anytype) NotificationManager {
        // Parse align from string
        const align_val: Align = if (std.mem.eql(u8, cfg.alignment, "left")) .left else if (std.mem.eql(u8, cfg.alignment, "right")) .right else .center;

        return .{
            .allocator = allocator,
            .current = null,
            .queue = .empty,
            .default_style = .{
                .fg = .{ .palette = cfg.fg },
                .bg = .{ .palette = cfg.bg },
                .bold = cfg.bold,
                .padding_x = cfg.padding_x,
                .padding_y = cfg.padding_y,
                .offset = cfg.offset,
                .alignment = align_val,
            },
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
        self.showWithOptions(message, self.default_duration_ms, self.default_style, false);
    }

    /// Show a notification for a specific duration
    pub fn showFor(self: *NotificationManager, message: []const u8, duration_ms: i64) void {
        self.showWithOptions(message, duration_ms, self.default_style, false);
    }

    /// Show a notification with full options
    pub fn showWithOptions(
        self: *NotificationManager,
        message: []const u8,
        duration_ms: i64,
        style: Style,
        owned: bool,
    ) void {
        const notif = Notification{
            .message = message,
            .expires_at = std.time.milliTimestamp() + duration_ms,
            .owned = owned,
            .style = style,
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

    /// Render the notification overlay (full screen - for MUX realm)
    pub fn render(self: *NotificationManager, renderer: *Renderer, screen_width: u16, screen_height: u16) void {
        self.renderInBounds(renderer, 0, 0, screen_width, screen_height, true);
    }

    /// Render notification within a bounded area (for PANE realm)
    /// bounds_x, bounds_y: top-left corner of the render area
    /// bounds_width, bounds_height: dimensions of the render area
    /// is_mux_realm: true for MUX (top), false for PANE (bottom)
    pub fn renderInBounds(
        self: *NotificationManager,
        renderer: *Renderer,
        bounds_x: u16,
        bounds_y: u16,
        bounds_width: u16,
        bounds_height: u16,
        is_mux_realm: bool,
    ) void {
        const notif = self.current orelse return;
        const style = notif.style;

        // Calculate box dimensions (constrained to bounds)
        const max_msg_len = bounds_width -| style.padding_x * 2;
        const msg_len: u16 = @intCast(@min(notif.message.len, max_msg_len));
        if (msg_len == 0) return;

        const box_width = msg_len + style.padding_x * 2;
        const box_height: u16 = 1 + style.padding_y * 2;

        // Calculate position within bounds
        const pos = self.calculatePositionInBounds(
            box_width,
            box_height,
            bounds_x,
            bounds_y,
            bounds_width,
            bounds_height,
            style,
            is_mux_realm,
        );

        // Draw background/border box
        var yi: u16 = 0;
        while (yi < box_height) : (yi += 1) {
            var xi: u16 = 0;
            while (xi < box_width) : (xi += 1) {
                renderer.setCell(pos.x + xi, pos.y + yi, .{
                    .char = ' ',
                    .fg = style.fg,
                    .bg = style.bg,
                });
            }
        }

        // Draw message text (centered in box)
        const text_y = pos.y + style.padding_y;
        const text_x = pos.x + style.padding_x;
        for (0..msg_len) |i| {
            renderer.setCell(text_x + @as(u16, @intCast(i)), text_y, .{
                .char = notif.message[i],
                .fg = style.fg,
                .bg = style.bg,
                .bold = style.bold,
            });
        }
    }

    fn calculatePositionInBounds(
        self: *NotificationManager,
        box_width: u16,
        box_height: u16,
        bounds_x: u16,
        bounds_y: u16,
        bounds_width: u16,
        bounds_height: u16,
        style: Style,
        is_mux_realm: bool,
    ) struct { x: u16, y: u16 } {
        _ = self;

        // Horizontal alignment (relative to bounds) using style.alignment
        const x: u16 = switch (style.alignment) {
            .left => bounds_x,
            .center => bounds_x + (bounds_width -| box_width) / 2,
            .right => bounds_x + bounds_width -| box_width,
        };

        // Vertical position using style.offset
        // MUX realm: offset = cells DOWN from top
        // PANE realm: offset = cells UP from bottom
        const y: u16 = if (is_mux_realm)
            bounds_y + style.offset
        else
            bounds_y + bounds_height -| box_height -| style.offset;

        return .{ .x = x, .y = y };
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
