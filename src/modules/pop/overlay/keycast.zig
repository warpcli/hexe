const std = @import("std");

/// Keycast entry for displaying recent keypresses
pub const KeycastEntry = struct {
    text: [32]u8,
    len: u8,
    expires_at: i64,

    pub fn getText(self: *const KeycastEntry) []const u8 {
        return self.text[0..self.len];
    }
};

/// Keycast state - tracks recent keypresses for display
pub const KeycastState = struct {
    enabled: bool,
    history: [8]KeycastEntry,
    count: u8,
    duration_ms: i64,

    pub fn init() KeycastState {
        return .{
            .enabled = false,
            .history = undefined,
            .count = 0,
            .duration_ms = 2000,
        };
    }

    /// Toggle keycast mode on/off
    pub fn toggle(self: *KeycastState) void {
        self.enabled = !self.enabled;
        if (!self.enabled) {
            self.count = 0;
        }
    }

    /// Record a keypress for display
    pub fn record(self: *KeycastState, text: []const u8) void {
        if (!self.enabled) return;
        if (text.len == 0 or text.len > 32) return;

        // Shift history if full
        if (self.count >= 8) {
            var i: u8 = 0;
            while (i + 1 < 8) : (i += 1) {
                self.history[i] = self.history[i + 1];
            }
            self.count = 7;
        }

        // Add new entry
        var entry: KeycastEntry = .{
            .text = undefined,
            .len = @intCast(text.len),
            .expires_at = std.time.milliTimestamp() + self.duration_ms,
        };
        @memcpy(entry.text[0..text.len], text);
        self.history[self.count] = entry;
        self.count += 1;
    }

    /// Update state, expire old entries. Returns true if changed.
    pub fn update(self: *KeycastState) bool {
        if (!self.enabled or self.count == 0) return false;

        const now = std.time.milliTimestamp();
        var changed = false;

        var i: u8 = 0;
        while (i < self.count) {
            if (now >= self.history[i].expires_at) {
                // Shift remaining entries down
                var j: u8 = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.history[j] = self.history[j + 1];
                }
                self.count -= 1;
                changed = true;
                continue;
            }
            i += 1;
        }

        return changed;
    }

    /// Check if there's content to render
    pub fn hasContent(self: *const KeycastState) bool {
        return self.enabled and self.count > 0;
    }

    /// Get entries for rendering
    pub fn getEntries(self: *const KeycastState) []const KeycastEntry {
        return self.history[0..self.count];
    }
};
