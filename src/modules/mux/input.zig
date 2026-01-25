const std = @import("std");
const pop = @import("pop");

const Pane = @import("pane.zig").Pane;

/// Convert arrow key escape sequences to vim-style keys for popup navigation
pub fn convertArrowKey(input: []const u8) u8 {
    if (input.len == 0) return 0;
    // Check for ESC sequences
    if (input[0] == 0x1b) {
        // Arrow keys: ESC [ A/B/C/D
        if (input.len >= 3 and input[1] == '[') {
            return switch (input[2]) {
                'C' => 'l', // Right arrow -> toggle
                'D' => 'h', // Left arrow -> toggle
                'A' => 'k', // Up arrow -> up (picker)
                'B' => 'j', // Down arrow -> down (picker)
                else => 0, // Ignore other CSI sequences
            };
        }
        // Alt+key: ESC followed by printable char (not '[' or 'O')
        // Ignore these - return 0
        if (input.len >= 2 and input[1] != '[' and input[1] != 'O') {
            return 0; // Ignore Alt+key
        }
        // Bare ESC key (no following char, or timeout)
        return 27; // ESC to cancel
    }
    return input[0];
}

/// Handle popup input and return true if popup was dismissed
pub fn handlePopupInput(popups: *pop.PopupManager, input: []const u8) bool {
    const key = convertArrowKey(input);
    const result = popups.handleInput(key);
    return result == .dismissed;
}

/// Handle scroll-related escape sequences for a pane
/// Returns number of bytes consumed, or null if not a scroll sequence
pub fn handlePaneScrollKeys(pane: *Pane, input: []const u8) ?usize {
    // Must start with ESC [
    if (input.len < 3 or input[0] != 0x1b or input[1] != '[') return null;

    // SGR mouse format: ESC [ < btn ; x ; y M (press) or m (release)
    if (input.len >= 4 and input[2] == '<') {
        // Find the 'M' or 'm' terminator
        var end: usize = 3;
        while (end < input.len and input[end] != 'M' and input[end] != 'm') : (end += 1) {}
        if (end >= input.len) return null;

        // Parse: btn ; x ; y
        var btn: u16 = 0;
        var field: u8 = 0;
        var i: usize = 3;
        while (i < end) : (i += 1) {
            if (input[i] == ';') {
                field += 1;
            } else if (input[i] >= '0' and input[i] <= '9') {
                const digit = input[i] - '0';
                switch (field) {
                    0 => btn = btn * 10 + digit,
                    else => {},
                }
            }
        }

        // Button 64 = wheel up, 65 = wheel down
        if (btn == 64) {
            pane.scrollUp(3);
            return end + 1;
        } else if (btn == 65) {
            pane.scrollDown(3);
            return end + 1;
        }

        // Other mouse events - consume but don't act
        return end + 1;
    }

    // Page Up: ESC [ 5 ~
    if (input.len >= 4 and input[2] == '5' and input[3] == '~') {
        pane.scrollUp(pane.height / 2);
        return 4;
    }

    // Page Down: ESC [ 6 ~
    if (input.len >= 4 and input[2] == '6' and input[3] == '~') {
        pane.scrollDown(pane.height / 2);
        return 4;
    }

    // Shift+Page Up: ESC [ 5 ; 2 ~
    if (input.len >= 6 and input[2] == '5' and input[3] == ';' and input[4] == '2' and input[5] == '~') {
        pane.scrollUp(pane.height);
        return 6;
    }

    // Shift+Page Down: ESC [ 6 ; 2 ~
    if (input.len >= 6 and input[2] == '6' and input[3] == ';' and input[4] == '2' and input[5] == '~') {
        pane.scrollDown(pane.height);
        return 6;
    }

    // Home (scroll to top): ESC [ H or ESC [ 1 ~
    if (input.len >= 3 and input[2] == 'H') {
        pane.scrollToTop();
        return 3;
    }
    if (input.len >= 4 and input[2] == '1' and input[3] == '~') {
        pane.scrollToTop();
        return 4;
    }

    // End (scroll to bottom): ESC [ F or ESC [ 4 ~
    if (input.len >= 3 and input[2] == 'F') {
        pane.scrollToBottom();
        return 3;
    }
    if (input.len >= 4 and input[2] == '4' and input[3] == '~') {
        pane.scrollToBottom();
        return 4;
    }

    // Shift+Up: ESC [ 1 ; 2 A - scroll up one line
    if (input.len >= 6 and input[2] == '1' and input[3] == ';' and input[4] == '2' and input[5] == 'A') {
        pane.scrollUp(1);
        return 6;
    }

    // Shift+Down: ESC [ 1 ; 2 B - scroll down one line
    if (input.len >= 6 and input[2] == '1' and input[3] == ';' and input[4] == '2' and input[5] == 'B') {
        pane.scrollDown(1);
        return 6;
    }

    return null;
}

/// Parse SGR mouse event from input
/// Returns mouse event info or null if not a mouse event
pub const MouseEvent = struct {
    btn: u16,
    x: u16,
    y: u16,
    is_release: bool,
    consumed: usize,
};

pub fn parseMouseEvent(input: []const u8) ?MouseEvent {
    // Must start with ESC [ <
    if (input.len < 4 or input[0] != 0x1b or input[1] != '[' or input[2] != '<') return null;

    // Find the 'M' or 'm' terminator
    var end: usize = 3;
    while (end < input.len and input[end] != 'M' and input[end] != 'm') : (end += 1) {}
    if (end >= input.len) return null;

    const is_release = input[end] == 'm';

    // Parse: btn ; x ; y
    var btn: u16 = 0;
    var mouse_x: u16 = 0;
    var mouse_y: u16 = 0;
    var field: u8 = 0;
    var i: usize = 3;
    while (i < end) : (i += 1) {
        if (input[i] == ';') {
            field += 1;
        } else if (input[i] >= '0' and input[i] <= '9') {
            const digit = input[i] - '0';
            switch (field) {
                0 => btn = btn * 10 + digit,
                1 => mouse_x = mouse_x * 10 + digit,
                2 => mouse_y = mouse_y * 10 + digit,
                else => {},
            }
        }
    }

    // Convert from 1-based to 0-based coordinates
    if (mouse_x > 0) mouse_x -= 1;
    if (mouse_y > 0) mouse_y -= 1;

    return MouseEvent{
        .btn = btn,
        .x = mouse_x,
        .y = mouse_y,
        .is_release = is_release,
        .consumed = end + 1,
    };
}
