const ghostty = @import("ghostty-vt");

/// Color representation used by mux rendering paths.
pub const Color = union(enum) {
    none,
    palette: u8,
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,

        pub fn eql(self: RGB, other: RGB) bool {
            return self.r == other.r and self.g == other.g and self.b == other.b;
        }
    };

    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .none => other == .none,
            .palette => |p| other == .palette and other.palette == p,
            .rgb => |rgb| other == .rgb and rgb.eql(other.rgb),
        };
    }

    pub fn fromStyleColor(c: ghostty.Style.Color) Color {
        return switch (c) {
            .none => .none,
            .palette => |p| .{ .palette = p },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        };
    }
};

/// Represents a single rendered cell with style attributes.
pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .none,
    bg: Color = .none,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: Underline = .none,
    strikethrough: bool = false,
    inverse: bool = false,
    is_wide_spacer: bool = false,
    is_wide_char: bool = false,

    pub const Underline = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and
            self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.bold == other.bold and
            self.italic == other.italic and
            self.faint == other.faint and
            self.underline == other.underline and
            self.strikethrough == other.strikethrough and
            self.inverse == other.inverse;
    }
};

/// Cursor information for rendering.
pub const CursorInfo = struct {
    x: u16 = 0,
    y: u16 = 0,
    style: u8 = 0,
    visible: bool = true,
};
