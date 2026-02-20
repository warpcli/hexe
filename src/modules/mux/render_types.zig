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

/// Cursor information for rendering.
pub const CursorInfo = struct {
    x: u16 = 0,
    y: u16 = 0,
    style: u8 = 0,
    visible: bool = true,
};
