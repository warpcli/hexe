const std = @import("std");

/// Color representation - compatible with mux/render.zig Color
pub const Color = union(enum) {
    none,
    palette: u8, // 0-255
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    /// Parse a color from string
    /// Supports: "red", "1", "237", "#ff5500", "rgb(255,85,0)"
    pub fn parse(str: []const u8) ?Color {
        const trimmed = std.mem.trim(u8, str, " \t");
        if (trimmed.len == 0) return null;

        // Named colors
        if (fromName(trimmed)) |c| return c;

        // Hex color: #RRGGBB or #RGB
        if (trimmed[0] == '#') {
            return parseHex(trimmed[1..]);
        }

        // Numeric palette: just a number
        const num = std.fmt.parseInt(u8, trimmed, 10) catch return null;
        return .{ .palette = num };
    }

    fn parseHex(hex: []const u8) ?Color {
        if (hex.len == 6) {
            const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
            const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
            const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        } else if (hex.len == 3) {
            const r = std.fmt.parseInt(u8, hex[0..1], 16) catch return null;
            const g = std.fmt.parseInt(u8, hex[1..2], 16) catch return null;
            const b = std.fmt.parseInt(u8, hex[2..3], 16) catch return null;
            return .{ .rgb = .{ .r = r * 17, .g = g * 17, .b = b * 17 } };
        }
        return null;
    }

    /// Named color lookup
    pub fn fromName(name: []const u8) ?Color {
        const names = std.StaticStringMap(u8).initComptime(.{
            .{ "black", 0 },
            .{ "red", 1 },
            .{ "green", 2 },
            .{ "yellow", 3 },
            .{ "blue", 4 },
            .{ "magenta", 5 },
            .{ "purple", 5 },
            .{ "cyan", 6 },
            .{ "white", 7 },
            .{ "bright_black", 8 },
            .{ "bright_red", 9 },
            .{ "bright_green", 10 },
            .{ "bright_yellow", 11 },
            .{ "bright_blue", 12 },
            .{ "bright_magenta", 13 },
            .{ "bright_cyan", 14 },
            .{ "bright_white", 15 },
        });

        if (names.get(name)) |idx| {
            return .{ .palette = idx };
        }
        return null;
    }

    /// Write ANSI foreground color sequence
    pub fn toAnsiFg(self: Color, writer: anytype) !void {
        switch (self) {
            .none => try writer.writeAll("\x1b[39m"),
            .palette => |idx| {
                if (idx < 8) {
                    try writer.print("\x1b[{d}m", .{30 + idx});
                } else if (idx < 16) {
                    try writer.print("\x1b[{d}m", .{90 + idx - 8});
                } else {
                    try writer.print("\x1b[38;5;{d}m", .{idx});
                }
            },
            .rgb => |rgb| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        }
    }

    /// Write ANSI background color sequence
    pub fn toAnsiBg(self: Color, writer: anytype) !void {
        switch (self) {
            .none => try writer.writeAll("\x1b[49m"),
            .palette => |idx| {
                if (idx < 8) {
                    try writer.print("\x1b[{d}m", .{40 + idx});
                } else if (idx < 16) {
                    try writer.print("\x1b[{d}m", .{100 + idx - 8});
                } else {
                    try writer.print("\x1b[48;5;{d}m", .{idx});
                }
            },
            .rgb => |rgb| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        }
    }
};

/// Style with foreground, background, and attributes
pub const Style = struct {
    fg: Color = .none,
    bg: Color = .none,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,

    /// Parse a style string like "bold bg:237 fg:15" or "bg:1 fg:0"
    pub fn parse(str: []const u8) Style {
        var result = Style{};
        var iter = std.mem.tokenizeAny(u8, str, " \t");

        while (iter.next()) |token| {
            // Check for fg:COLOR or bg:COLOR
            if (std.mem.startsWith(u8, token, "fg:")) {
                if (Color.parse(token[3..])) |c| {
                    result.fg = c;
                }
            } else if (std.mem.startsWith(u8, token, "bg:")) {
                if (Color.parse(token[3..])) |c| {
                    result.bg = c;
                }
            } else if (std.mem.eql(u8, token, "bold")) {
                result.bold = true;
            } else if (std.mem.eql(u8, token, "italic")) {
                result.italic = true;
            } else if (std.mem.eql(u8, token, "underline")) {
                result.underline = true;
            } else if (std.mem.eql(u8, token, "dim")) {
                result.dim = true;
            } else {
                // Try as a color name or number (defaults to foreground)
                if (Color.parse(token)) |c| {
                    result.fg = c;
                }
            }
        }

        return result;
    }

    /// Write ANSI escape sequences for this style
    pub fn toAnsi(self: Style, writer: anytype) !void {
        // Attributes
        if (self.bold) try writer.writeAll("\x1b[1m");
        if (self.dim) try writer.writeAll("\x1b[2m");
        if (self.italic) try writer.writeAll("\x1b[3m");
        if (self.underline) try writer.writeAll("\x1b[4m");

        // Colors
        if (self.fg != .none) try self.fg.toAnsiFg(writer);
        if (self.bg != .none) try self.bg.toAnsiBg(writer);
    }

    /// Reset all attributes
    pub fn reset(writer: anytype) !void {
        try writer.writeAll("\x1b[0m");
    }

    /// Check if style has any attributes set
    pub fn isEmpty(self: Style) bool {
        return self.fg == .none and self.bg == .none and
            !self.bold and !self.italic and !self.underline and !self.dim;
    }
};
