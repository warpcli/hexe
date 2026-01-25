const std = @import("std");

/// Convert 16 binary bytes to 32 hex characters.
pub fn binToHex(uuid_bin: [16]u8) [32]u8 {
    const hex_chars = "0123456789abcdef";
    var hex: [32]u8 = undefined;
    for (uuid_bin, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

/// Convert 32 hex characters to 16 binary bytes. Returns null if invalid hex.
pub fn hexToBin(hex: [32]u8) ?[16]u8 {
    var bin: [16]u8 = undefined;
    for (0..16) |i| {
        const hi = hexVal(hex[i * 2]) orelse return null;
        const lo = hexVal(hex[i * 2 + 1]) orelse return null;
        bin[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return bin;
}

/// Convert a single hex character to its value (0-15).
pub fn hexVal(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Generate a new random UUID (16 bytes).
pub fn generate() [16]u8 {
    var uuid: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid);
    return uuid;
}

/// Generate a new random UUID as hex string (32 bytes).
pub fn generateHex() [32]u8 {
    return binToHex(generate());
}

/// Check if two UUIDs (as 32-char hex) are equal.
pub fn eql(a: [32]u8, b: [32]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Zero UUID constant for comparison.
pub const zero: [32]u8 = .{0} ** 32;
pub const zero_bin: [16]u8 = .{0} ** 16;

test "binToHex roundtrip" {
    const bin = [16]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    const hex = binToHex(bin);
    const back = hexToBin(hex).?;
    try std.testing.expectEqualSlices(u8, &bin, &back);
}
