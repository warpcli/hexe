const vaxis = @import("vaxis");

pub fn toVaxisColor(c: anytype) vaxis.Color {
    return switch (c) {
        .none => .default,
        .palette => |idx| .{ .index = idx },
        .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
    };
}
