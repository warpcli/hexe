const std = @import("std");
const style = @import("style.zig");
pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const InputResult = style.InputResult;

/// Options for creating a picker
pub const PickerOptions = struct {
    style: ?Style = null,
    visible_count: usize = 10,
    title: ?[]const u8 = null,
    timeout_ms: ?i64 = null, // Auto-cancel after this many milliseconds (null = no timeout)
};

/// Picker/Choose - Multi-option selector blocking popup
pub const Picker = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,
    items_owned: bool,
    selected: usize,
    scroll_offset: usize,
    visible_count: usize,
    style: Style,
    title: ?[]const u8,
    title_owned: bool,
    result: ?usize, // null if cancelled, index if selected
    cancelled: bool,
    timeout_ms: ?i64, // Auto-cancel timeout (null = no timeout)
    created_at: i64, // Timestamp when created (milliseconds)

    pub fn init(allocator: std.mem.Allocator, items: []const []const u8, opts: PickerOptions) Picker {
        const visible = @min(opts.visible_count, items.len);
        return .{
            .allocator = allocator,
            .items = items,
            .items_owned = false,
            .selected = 0,
            .scroll_offset = 0,
            .visible_count = visible,
            .style = opts.style orelse Style.withColors(7, 0), // white on black
            .title = opts.title,
            .title_owned = false,
            .result = null,
            .cancelled = false,
            .timeout_ms = opts.timeout_ms,
            .created_at = std.time.milliTimestamp(),
        };
    }

    /// Create with owned items (will be freed on deinit)
    pub fn initOwned(allocator: std.mem.Allocator, items: []const []const u8, opts: PickerOptions) !Picker {
        // Dupe items
        var owned_items = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            owned_items[i] = try allocator.dupe(u8, item);
        }
        var picker = init(allocator, owned_items, opts);
        picker.items_owned = true;

        // Dupe title if provided
        if (opts.title) |t| {
            picker.title = try allocator.dupe(u8, t);
            picker.title_owned = true;
        }

        return picker;
    }

    pub fn deinit(self: *Picker) void {
        if (self.items_owned) {
            for (self.items) |item| {
                self.allocator.free(item);
            }
            self.allocator.free(self.items);
        }
        if (self.title_owned) {
            if (self.title) |t| {
                self.allocator.free(t);
            }
        }
    }

    /// Handle keyboard input
    /// Up/Down arrows (mapped to k/j), Enter to select, ESC to cancel
    pub fn handleInput(self: *Picker, key: u8) InputResult {
        switch (key) {
            'j', 'J' => { // Down
                self.moveDown();
                return .consumed;
            },
            'k', 'K' => { // Up
                self.moveUp();
                return .consumed;
            },
            '\r', ' ' => { // Enter or Space selects
                self.result = self.selected;
                return .dismissed;
            },
            27 => { // ESC cancels
                self.cancelled = true;
                self.result = null;
                return .dismissed;
            },
            else => return .consumed, // Consume all other input when popup is active
        }
    }

    /// Move selection down
    pub fn moveDown(self: *Picker) void {
        if (self.items.len == 0) return;
        if (self.selected < self.items.len - 1) {
            self.selected += 1;
            // Adjust scroll if needed
            if (self.selected >= self.scroll_offset + self.visible_count) {
                self.scroll_offset = self.selected - self.visible_count + 1;
            }
        }
    }

    /// Move selection up
    pub fn moveUp(self: *Picker) void {
        if (self.selected > 0) {
            self.selected -= 1;
            // Adjust scroll if needed
            if (self.selected < self.scroll_offset) {
                self.scroll_offset = self.selected;
            }
        }
    }

    /// Move to top
    pub fn moveToTop(self: *Picker) void {
        self.selected = 0;
        self.scroll_offset = 0;
    }

    /// Move to bottom
    pub fn moveToBottom(self: *Picker) void {
        if (self.items.len == 0) return;
        self.selected = self.items.len - 1;
        if (self.items.len > self.visible_count) {
            self.scroll_offset = self.items.len - self.visible_count;
        }
    }

    /// Get the result (null if cancelled, index if selected)
    pub fn getResult(self: *Picker) ?usize {
        return self.result;
    }

    /// Check if cancelled
    pub fn wasCancelled(self: *Picker) bool {
        return self.cancelled;
    }

    /// Check if this is a blocking popup
    pub fn isBlocking(_: *Picker) bool {
        return true;
    }

    /// Check if the popup has timed out
    pub fn isTimedOut(self: *Picker) bool {
        if (self.timeout_ms) |timeout| {
            const now = std.time.milliTimestamp();
            return (now - self.created_at) >= timeout;
        }
        return false;
    }

    /// Force timeout (set result to cancelled)
    pub fn forceTimeout(self: *Picker) void {
        self.cancelled = true;
        self.result = null;
    }

    /// Calculate required box dimensions
    pub fn getBoxDimensions(self: *Picker) struct { width: u16, height: u16 } {
        const s = self.style;

        // Find max item width
        var max_item_width: usize = 0;
        for (self.items) |item| {
            max_item_width = @max(max_item_width, item.len);
        }

        // Include title width if present
        var title_width: usize = 0;
        if (self.title) |t| {
            title_width = t.len + 4; // " Title "
        }

        // Add space for selection indicator ">" and padding
        const content_width = @max(max_item_width + 2, title_width); // +2 for "> "
        const box_width: u16 = @intCast(content_width + s.padding_x * 2);

        // Height: visible items + padding + title (if any)
        var box_height: u16 = @intCast(self.visible_count + s.padding_y * 2);
        if (self.title != null) {
            box_height += 1; // Title line
        }

        return .{ .width = box_width, .height = box_height };
    }
};
