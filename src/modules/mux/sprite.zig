const std = @import("std");
const core = @import("core");
const sprites_embedded = core.sprites_embedded;

/// Sprite display state
pub const SpriteState = struct {
    show_sprite: bool = false,
    sprite_name: ?[]const u8 = null,
    sprite_content: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SpriteState {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SpriteState) void {
        if (self.sprite_content) |content| {
            self.allocator.free(content);
        }
        self.* = .{ .allocator = self.allocator };
    }

    /// Load a sprite by name from embedded sprite data
    pub fn loadSprite(self: *SpriteState, name: []const u8, shiny: bool) !void {
        // Clean up previous sprite
        if (self.sprite_content) |content| {
            self.allocator.free(content);
            self.sprite_content = null;
        }

        // Get sprite from embedded data
        const sprite_data = sprites_embedded.getSprite(name, shiny) orelse return error.SpriteNotFound;

        // Duplicate the embedded data so we can free it later
        const content = try self.allocator.dupe(u8, sprite_data);

        self.sprite_content = content;
        self.sprite_name = name;
        self.show_sprite = true;
    }

    /// Toggle sprite display
    pub fn toggle(self: *SpriteState) void {
        self.show_sprite = !self.show_sprite;
    }

    /// Hide sprite
    pub fn hide(self: *SpriteState) void {
        self.show_sprite = false;
    }
};

/// Render a sprite overlay centered in the pane
pub fn renderSpriteOverlay(
    buf: []u8,
    pane_x: u16,
    pane_y: u16,
    pane_width: u16,
    pane_height: u16,
    sprite_content: []const u8,
) !usize {
    // Parse sprite dimensions by counting lines and max line width
    var lines = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer lines.deinit();

    var line_iter = std.mem.splitScalar(u8, sprite_content, '\n');
    var max_visual_width: usize = 0;

    while (line_iter.next()) |line| {
        try lines.append(line);
        // Estimate visual width (ignoring ANSI codes)
        const visual_width = estimateVisualWidth(line);
        if (visual_width > max_visual_width) {
            max_visual_width = visual_width;
        }
    }

    const sprite_height: u16 = @intCast(lines.items.len);
    const sprite_width: u16 = @intCast(max_visual_width);

    // Calculate center position
    const start_y = if (pane_height > sprite_height)
        pane_y + (pane_height - sprite_height) / 2
    else
        pane_y;

    const start_x = if (pane_width > sprite_width)
        pane_x + (pane_width - sprite_width) / 2
    else
        pane_x;

    // Render the sprite
    var written: usize = 0;
    for (lines.items, 0..) |line, i| {
        const y = start_y + @as(u16, @intCast(i));
        if (y >= pane_y + pane_height) break;

        // Position cursor
        written += (try std.fmt.bufPrint(
            buf[written..],
            "\x1b[{d};{d}H",
            .{ y + 1, start_x + 1 },
        )).len;

        // Write the line
        const to_write = @min(line.len, buf.len - written);
        @memcpy(buf[written..][0..to_write], line[0..to_write]);
        written += to_write;

        // Reset at end of line
        const reset = "\x1b[0m";
        @memcpy(buf[written..][0..reset.len], reset);
        written += reset.len;
    }

    return written;
}

/// Estimate visual width of a line (ignoring ANSI escape sequences)
pub fn estimateVisualWidth(line: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    var in_escape = false;

    while (i < line.len) : (i += 1) {
        if (line[i] == 0x1b) { // ESC
            in_escape = true;
        } else if (in_escape) {
            if (line[i] == 'm') {
                in_escape = false;
            }
        } else {
            // Count visible characters
            // Unicode box-drawing characters count as 1
            width += 1;
        }
    }

    return width;
}
