const std = @import("std");
const core = @import("core");
const Style = core.style.Style;
const Segment = core.segments.Segment;
const Context = core.segments.Context;

/// Format string parser for Starship-compatible format strings
/// Supports:
/// - $variable           → Render segment named "variable"
/// - ${custom.name}      → Render custom segment
/// - [text](style)       → Literal text with style
/// - Plain text          → Literal text with no style
pub const FormatParser = struct {
    allocator: std.mem.Allocator,
    format: []const u8,
    pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, format: []const u8) FormatParser {
        return .{
            .allocator = allocator,
            .format = format,
        };
    }

    /// Render the format string with the given context
    pub fn render(self: *FormatParser, ctx: *Context) ![]Segment {
        var segments_list = std.ArrayList(Segment).init(self.allocator);
        errdefer segments_list.deinit();

        while (self.pos < self.format.len) {
            const c = self.format[self.pos];

            if (c == '$') {
                // Variable reference
                try self.parseVariable(&segments_list, ctx);
            } else if (c == '[') {
                // Styled text: [text](style)
                try self.parseStyledText(&segments_list);
            } else if (c == '\\' and self.pos + 1 < self.format.len) {
                // Escape sequence
                self.pos += 1;
                const next = self.format[self.pos];
                try segments_list.append(.{
                    .text = self.format[self.pos .. self.pos + 1],
                    .style = Style{},
                });
                self.pos += 1;
                _ = next;
            } else {
                // Literal text - collect until special char
                const start = self.pos;
                while (self.pos < self.format.len) {
                    const ch = self.format[self.pos];
                    if (ch == '$' or ch == '[' or ch == '\\') break;
                    self.pos += 1;
                }
                if (self.pos > start) {
                    try segments_list.append(.{
                        .text = self.format[start..self.pos],
                        .style = Style{},
                    });
                }
            }
        }

        return segments_list.toOwnedSlice();
    }

    fn parseVariable(self: *FormatParser, segments_list: *std.ArrayList(Segment), ctx: *Context) !void {
        self.pos += 1; // skip '$'

        if (self.pos >= self.format.len) return;

        var name: []const u8 = undefined;

        if (self.format[self.pos] == '{') {
            // ${name} or ${custom.name} syntax
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.format.len and self.format[self.pos] != '}') {
                self.pos += 1;
            }
            name = self.format[start..self.pos];
            if (self.pos < self.format.len) self.pos += 1; // skip '}'
        } else {
            // $name syntax - collect word chars
            const start = self.pos;
            while (self.pos < self.format.len) {
                const ch = self.format[self.pos];
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') break;
                self.pos += 1;
            }
            name = self.format[start..self.pos];
        }

        if (name.len == 0) return;

        // Render the segment
        if (ctx.renderSegment(name)) |segs| {
            for (segs) |seg| {
                try segments_list.append(seg);
            }
        }
    }

    fn parseStyledText(self: *FormatParser, segments_list: *std.ArrayList(Segment)) !void {
        self.pos += 1; // skip '['

        // Find matching ']'
        const text_start = self.pos;
        var bracket_depth: usize = 1;
        while (self.pos < self.format.len) {
            const ch = self.format[self.pos];
            if (ch == '[') {
                bracket_depth += 1;
            } else if (ch == ']') {
                bracket_depth -= 1;
                if (bracket_depth == 0) break;
            }
            self.pos += 1;
        }

        const text = self.format[text_start..self.pos];
        if (self.pos < self.format.len) self.pos += 1; // skip ']'

        // Check for (style)
        var style = Style{};
        if (self.pos < self.format.len and self.format[self.pos] == '(') {
            self.pos += 1;
            const style_start = self.pos;
            while (self.pos < self.format.len and self.format[self.pos] != ')') {
                self.pos += 1;
            }
            const style_str = self.format[style_start..self.pos];
            if (self.pos < self.format.len) self.pos += 1; // skip ')'
            style = Style.parse(style_str);
        }

        // Add the styled text segment
        if (text.len > 0) {
            try segments_list.append(.{
                .text = text,
                .style = style,
            });
        }
    }
};

test "parse simple format" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var parser = FormatParser.init(std.testing.allocator, "hello $time world");
    const segs = try parser.render(&ctx);
    defer std.testing.allocator.free(segs);

    // Should have "hello " and " world" as literals
    // $time would be rendered by context
}

test "parse styled text" {
    var ctx = Context.init(std.testing.allocator);
    defer ctx.deinit();

    var parser = FormatParser.init(std.testing.allocator, "[|](fg:7)");
    const segs = try parser.render(&ctx);
    defer std.testing.allocator.free(segs);

    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqualStrings("|", segs[0].text);
    try std.testing.expectEqual(@as(u8, 7), segs[0].style.fg.palette);
}
