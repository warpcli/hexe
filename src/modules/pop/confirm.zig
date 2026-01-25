const std = @import("std");
const style = @import("style.zig");
pub const Style = style.Style;
pub const Color = style.Color;
pub const Align = style.Align;
pub const Bounds = style.Bounds;
pub const InputResult = style.InputResult;

/// Selection state for confirm dialog
pub const Selection = enum {
    yes,
    no,
};

/// Options for creating a confirm dialog
pub const ConfirmOptions = struct {
    style: ?Style = null,
    default: Selection = .no,
    yes_label: []const u8 = "Yes",
    no_label: []const u8 = "No",
    timeout_ms: ?i64 = null, // Auto-cancel after this many milliseconds (null = no timeout)
};

/// Confirm dialog - Yes/No blocking popup
pub const Confirm = struct {
    allocator: std.mem.Allocator,
    message: []const u8,
    message_owned: bool,
    selected: Selection,
    style: Style,
    yes_label: []const u8,
    no_label: []const u8,
    result: ?bool, // Set when dismissed
    timeout_ms: ?i64, // Auto-cancel timeout (null = no timeout)
    created_at: i64, // Timestamp when created (milliseconds)

    pub fn init(allocator: std.mem.Allocator, message: []const u8, opts: ConfirmOptions) Confirm {
        return .{
            .allocator = allocator,
            .message = message,
            .message_owned = false,
            .selected = opts.default,
            .style = opts.style orelse Style.withColors(0, 4), // black on blue
            .yes_label = opts.yes_label,
            .no_label = opts.no_label,
            .result = null,
            .timeout_ms = opts.timeout_ms,
            .created_at = std.time.milliTimestamp(),
        };
    }

    /// Create with owned message (will be freed on deinit)
    pub fn initOwned(allocator: std.mem.Allocator, message: []const u8, opts: ConfirmOptions) !Confirm {
        const owned_msg = try allocator.dupe(u8, message);
        var confirm = init(allocator, owned_msg, opts);
        confirm.message_owned = true;
        return confirm;
    }

    pub fn deinit(self: *Confirm) void {
        if (self.message_owned) {
            self.allocator.free(self.message);
        }
    }

    /// Handle keyboard input
    /// Left/Right arrows toggle, Enter to confirm, ESC to cancel
    pub fn handleInput(self: *Confirm, key: u8) InputResult {
        switch (key) {
            27 => { // ESC - cancel
                self.selected = .no;
                self.result = false;
                return .dismissed;
            },
            '\r' => { // Enter confirms current selection
                self.result = self.selected == .yes;
                return .dismissed;
            },
            // Left/Right toggle between options
            'h', 'H', 'l', 'L' => {
                self.toggle();
                return .consumed;
            },
            else => return .consumed, // Consume all other input when popup is active
        }
    }

    /// Toggle selection between yes and no
    pub fn toggle(self: *Confirm) void {
        self.selected = if (self.selected == .yes) .no else .yes;
    }

    /// Get the result (true = yes, false = no/cancelled)
    pub fn getResult(self: *Confirm) ?bool {
        return self.result;
    }

    /// Check if this is a blocking popup
    pub fn isBlocking(_: *Confirm) bool {
        return true;
    }

    /// Check if the popup has timed out
    pub fn isTimedOut(self: *Confirm) bool {
        if (self.timeout_ms) |timeout| {
            const now = std.time.milliTimestamp();
            return (now - self.created_at) >= timeout;
        }
        return false;
    }

    /// Force timeout (set result to false/cancelled)
    pub fn forceTimeout(self: *Confirm) void {
        self.selected = .no;
        self.result = false;
    }

    /// Calculate required box dimensions (including border)
    pub fn getBoxDimensions(self: *Confirm) struct { width: u16, height: u16 } {
        const s = self.style;
        // Box width: max of message width and buttons width + padding + border
        const msg_width: u16 = @intCast(self.message.len);
        // Buttons: [ Yes ]    [ No ] with 4 spaces between
        const buttons_width: u16 = @intCast(self.yes_label.len + self.no_label.len + 14); // "[ " + " ]" x2 + 4 spaces
        const content_width = @max(msg_width, buttons_width);
        const box_width = content_width + s.padding_x * 2 + 2; // +2 for left/right border
        const box_height: u16 = 3 + s.padding_y * 2 + 2; // message + blank + buttons + padding + top/bottom border
        return .{ .width = box_width, .height = box_height };
    }
};
