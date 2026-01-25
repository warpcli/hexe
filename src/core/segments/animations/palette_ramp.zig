const std = @import("std");

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

fn xterm16ToRgb(idx: u8) RGB {
    // Standard xterm 16-color table.
    // NOTE: 0-15 may be remapped by terminal themes (pywal), but this is
    // good enough for ramp generation.
    return switch (idx) {
        0 => .{ .r = 0, .g = 0, .b = 0 },
        1 => .{ .r = 205, .g = 0, .b = 0 },
        2 => .{ .r = 0, .g = 205, .b = 0 },
        3 => .{ .r = 205, .g = 205, .b = 0 },
        4 => .{ .r = 0, .g = 0, .b = 238 },
        5 => .{ .r = 205, .g = 0, .b = 205 },
        6 => .{ .r = 0, .g = 205, .b = 205 },
        7 => .{ .r = 229, .g = 229, .b = 229 },
        8 => .{ .r = 127, .g = 127, .b = 127 },
        9 => .{ .r = 255, .g = 0, .b = 0 },
        10 => .{ .r = 0, .g = 255, .b = 0 },
        11 => .{ .r = 255, .g = 255, .b = 0 },
        12 => .{ .r = 92, .g = 92, .b = 255 },
        13 => .{ .r = 255, .g = 0, .b = 255 },
        14 => .{ .r = 0, .g = 255, .b = 255 },
        15 => .{ .r = 255, .g = 255, .b = 255 },
        else => .{ .r = 0, .g = 0, .b = 0 },
    };
}

pub fn xterm256ToRgb(idx: u8) RGB {
    if (idx < 16) return xterm16ToRgb(idx);
    if (idx >= 232) {
        const v: u8 = @intCast(8 + 10 * (idx - 232));
        return .{ .r = v, .g = v, .b = v };
    }

    // 16..231: 6x6x6 cube.
    const n = idx - 16;
    const r = n / 36;
    const g = (n % 36) / 6;
    const b = n % 6;

    const steps = [_]u8{ 0, 95, 135, 175, 215, 255 };
    return .{ .r = steps[r], .g = steps[g], .b = steps[b] };
}

fn dist2(a: RGB, b: RGB) u32 {
    const dr: i32 = @as(i32, a.r) - @as(i32, b.r);
    const dg: i32 = @as(i32, a.g) - @as(i32, b.g);
    const db: i32 = @as(i32, a.b) - @as(i32, b.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

pub fn nearestXterm256(rgb: RGB) u8 {
    var best_idx: u8 = 0;
    var best_d: u32 = std.math.maxInt(u32);
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const idx: u8 = @intCast(i);
        const cand = xterm256ToRgb(idx);
        const d = dist2(rgb, cand);
        if (d < best_d) {
            best_d = d;
            best_idx = idx;
            if (best_d == 0) break;
        }
    }
    return best_idx;
}

threadlocal var RAMP_BUF: [32]u8 = undefined;

pub fn paletteRamp(fg: u8, bg: u8, count_in: u8) []const u8 {
    const count: u8 = if (count_in < 2) 2 else @min(count_in, @as(u8, @intCast(RAMP_BUF.len)));
    const a = xterm256ToRgb(fg);
    const b = xterm256ToRgb(bg);

    var i: u8 = 0;
    while (i < count) : (i += 1) {
        const t_num: u16 = @intCast(i);
        const t_den: u16 = @intCast(count - 1);

        const r: u8 = @intCast((@as(u16, a.r) * (t_den - t_num) + @as(u16, b.r) * t_num) / t_den);
        const g: u8 = @intCast((@as(u16, a.g) * (t_den - t_num) + @as(u16, b.g) * t_num) / t_den);
        const bl: u8 = @intCast((@as(u16, a.b) * (t_den - t_num) + @as(u16, b.b) * t_num) / t_den);

        RAMP_BUF[i] = nearestXterm256(.{ .r = r, .g = g, .b = bl });
    }
    return RAMP_BUF[0..count];
}
