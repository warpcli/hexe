const std = @import("std");
const pokemon = @import("pokemon.zig");

/// Keycast configuration
pub const KeycastConfig = struct {
    enabled: bool = false,
    position: pokemon.Position = .bottomright,
    duration_ms: i64 = 2000,           // How long entries stay visible
    max_entries: u8 = 8,                // Maximum history size
    grouping_timeout_ms: i64 = 500,    // Keys within this time get grouped (0.5s)
};

/// Keycast entry for displaying recent keypresses
pub const KeycastEntry = struct {
    text: [128]u8, // Increased to hold grouped keypresses
    len: u8,
    expires_at: i64,
    is_modifier_combo: bool, // True if this is a modifier key combo (Ctrl+S, etc.)

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
    grouping_timeout_ms: i64, // Keys within this time get grouped together
    last_keypress_time: i64, // Timestamp of last recorded keypress

    pub fn init() KeycastState {
        return .{
            .enabled = false,
            .history = undefined,
            .count = 0,
            .duration_ms = 2000,
            .grouping_timeout_ms = 500, // 0.5 seconds
            .last_keypress_time = 0,
        };
    }

    /// Toggle keycast mode on/off
    pub fn toggle(self: *KeycastState) void {
        self.enabled = !self.enabled;
        if (!self.enabled) {
            self.count = 0;
        }
    }

    /// Check if the key text contains a modifier combination
    fn isModifierCombo(text: []const u8) bool {
        // Check for common modifier patterns
        if (std.mem.indexOf(u8, text, "Ctrl") != null) return true;
        if (std.mem.indexOf(u8, text, "Alt") != null) return true;
        if (std.mem.indexOf(u8, text, "Shift") != null) return true;
        if (std.mem.indexOf(u8, text, "Meta") != null) return true;
        if (std.mem.indexOf(u8, text, "Super") != null) return true;
        if (std.mem.indexOf(u8, text, "Cmd") != null) return true;
        // If it contains "+" it's likely a combo (e.g., "Ctrl+S")
        if (std.mem.indexOf(u8, text, "+") != null) return true;
        return false;
    }

    /// Record a keypress for display
    /// Groups regular keys together if within grouping_timeout_ms
    /// Modifiers always start a new line
    pub fn record(self: *KeycastState, text: []const u8) void {
        if (!self.enabled) return;
        if (text.len == 0 or text.len > 128) return;

        const now = std.time.milliTimestamp();
        const is_modifier = isModifierCombo(text);
        const time_since_last = if (self.last_keypress_time > 0)
            now - self.last_keypress_time
        else
            self.grouping_timeout_ms + 1; // Force new entry on first key

        // Try to append to last entry if:
        // 1. Not a modifier combo
        // 2. Last entry exists and is not a modifier combo
        // 3. Within grouping timeout
        const can_append = !is_modifier and
            self.count > 0 and
            !self.history[self.count - 1].is_modifier_combo and
            time_since_last <= self.grouping_timeout_ms;

        if (can_append) {
            // Append to last entry
            const last = &self.history[self.count - 1];
            const new_len = last.len + @as(u8, @intCast(text.len));
            if (new_len <= 128) {
                @memcpy(last.text[last.len..][0..text.len], text);
                last.len = new_len;
                last.expires_at = now + self.duration_ms; // Extend expiration
                self.last_keypress_time = now;
                return;
            }
            // If appending would overflow, fall through to create new entry
        }

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
            .expires_at = now + self.duration_ms,
            .is_modifier_combo = is_modifier,
        };
        @memcpy(entry.text[0..text.len], text);
        self.history[self.count] = entry;
        self.count += 1;
        self.last_keypress_time = now;
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
