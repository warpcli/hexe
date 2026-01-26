//! ASCII art digits using Unicode block elements.
//! Supports multiple sizes with quadrant-based sub-cell rendering.
//!
//! Each terminal cell can represent a 2x2 pixel grid using quadrant blocks,
//! effectively doubling resolution in both dimensions.

/// Size options for digit rendering
pub const Size = enum {
    small, // 3x5 cells (6x10 pixels)
    medium, // 5x7 cells (10x14 pixels)
    large, // 7x9 cells (14x18 pixels)

    pub fn cellWidth(self: Size) u16 {
        return switch (self) {
            .small => 3,
            .medium => 5,
            .large => 7,
        };
    }

    pub fn cellHeight(self: Size) u16 {
        return switch (self) {
            .small => 5,
            .medium => 7,
            .large => 9,
        };
    }

    pub fn pixelWidth(self: Size) u16 {
        return self.cellWidth() * 2;
    }

    pub fn pixelHeight(self: Size) u16 {
        return self.cellHeight() * 2;
    }
};

/// Unicode block characters for quadrant rendering
pub const Block = struct {
    // Quadrant blocks (2x2 sub-cell pixels)
    pub const EMPTY: u21 = ' ';
    pub const UPPER_LEFT: u21 = 0x2598; // ▘
    pub const UPPER_RIGHT: u21 = 0x259D; // ▝
    pub const LOWER_LEFT: u21 = 0x2596; // ▖
    pub const LOWER_RIGHT: u21 = 0x2597; // ▗
    pub const UPPER_HALF: u21 = 0x2580; // ▀
    pub const LOWER_HALF: u21 = 0x2584; // ▄
    pub const LEFT_HALF: u21 = 0x258C; // ▌
    pub const RIGHT_HALF: u21 = 0x2590; // ▐
    pub const DIAG_ULDR: u21 = 0x259A; // ▚ (upper-left + lower-right)
    pub const DIAG_URDL: u21 = 0x259E; // ▞ (upper-right + lower-left)
    pub const TRI_UL_LL_LR: u21 = 0x2599; // ▙
    pub const TRI_UL_UR_LL: u21 = 0x259B; // ▛
    pub const TRI_UL_UR_LR: u21 = 0x259C; // ▜
    pub const TRI_UR_LL_LR: u21 = 0x259F; // ▟
    pub const FULL: u21 = 0x2588; // █

    /// Convert a 2x2 pixel pattern to the appropriate quadrant character
    /// Bits: 0=upper-left, 1=upper-right, 2=lower-left, 3=lower-right
    pub fn fromQuadrant(bits: u4) u21 {
        return switch (bits) {
            0b0000 => EMPTY,
            0b0001 => UPPER_LEFT,
            0b0010 => UPPER_RIGHT,
            0b0011 => UPPER_HALF,
            0b0100 => LOWER_LEFT,
            0b0101 => LEFT_HALF,
            0b0110 => DIAG_URDL,
            0b0111 => TRI_UL_UR_LL,
            0b1000 => LOWER_RIGHT,
            0b1001 => DIAG_ULDR,
            0b1010 => RIGHT_HALF,
            0b1011 => TRI_UL_UR_LR,
            0b1100 => LOWER_HALF,
            0b1101 => TRI_UL_LL_LR,
            0b1110 => TRI_UR_LL_LR,
            0b1111 => FULL,
        };
    }
};

/// Pixel bitmap for a digit (max 14x18 pixels for large size)
/// Uses fixed-size array to avoid comptime pointer issues
pub const PixelMap = struct {
    width: u8,
    height: u8,
    data: [4]u8, // Packed bits, row-major (enough for 5x5 = 25 bits)

    /// Get pixel at (x, y). Returns true if filled.
    pub fn get(self: PixelMap, x: u8, y: u8) bool {
        if (x >= self.width or y >= self.height) return false;
        const idx = @as(usize, y) * self.width + x;
        const byte_idx = idx / 8;
        const bit_idx: u3 = @intCast(idx % 8);
        if (byte_idx >= self.data.len) return false;
        return (self.data[byte_idx] >> (7 - bit_idx)) & 1 == 1;
    }

    /// Get quadrant bits for cell at (cx, cy)
    /// Returns 4-bit pattern: upper-left, upper-right, lower-left, lower-right
    pub fn getQuadrant(self: PixelMap, cx: u8, cy: u8) u4 {
        const px = cx * 2;
        const py = cy * 2;
        var bits: u4 = 0;
        if (self.get(px, py)) bits |= 0b0001; // upper-left
        if (self.get(px + 1, py)) bits |= 0b0010; // upper-right
        if (self.get(px, py + 1)) bits |= 0b0100; // lower-left
        if (self.get(px + 1, py + 1)) bits |= 0b1000; // lower-right
        return bits;
    }
};

// ============================================================================
// Note: Removed SMALL_* variants - using block-style only for now
// The block-style digits at 5x5 pixels are cleaner and more readable
// ============================================================================

// Simple 5x5 block-style digits (easier to read, compatible fallback)
const BLOCK_WIDTH: u8 = 5;
const BLOCK_HEIGHT: u8 = 5;

fn makeBlockDigit(comptime pattern: [5][5]u1) PixelMap {
    comptime {
        var data: [4]u8 = .{ 0, 0, 0, 0 };
        var bit_idx: usize = 0;
        for (pattern) |row| {
            for (row) |pixel| {
                if (pixel == 1) {
                    data[bit_idx / 8] |= @as(u8, 1) << @intCast(7 - (bit_idx % 8));
                }
                bit_idx += 1;
            }
        }
        return PixelMap{ .width = BLOCK_WIDTH, .height = BLOCK_HEIGHT, .data = data };
    }
}

// Block-style digits (5x5 pixels = 3x3 cells with quadrants, or 5x5 cells direct)
const BLOCK_DIGITS = [10]PixelMap{
    // 0
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // 1
    makeBlockDigit(.{
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 1, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 1, 1, 1, 0 },
    }),
    // 2
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // 3
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // 4
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 0, 0, 0, 0, 1 },
    }),
    // 5
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // 6
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // 7
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 0, 0, 0, 1, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
    }),
    // 8
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // 9
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
    }),
};

// Block-style letters (5x5 pixels)
const BLOCK_LETTERS = [26]PixelMap{
    // a
    makeBlockDigit(.{
        .{ 0, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // b
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 0 },
    }),
    // c
    makeBlockDigit(.{
        .{ 0, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 0, 1, 1, 1, 1 },
    }),
    // d
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 0 },
    }),
    // e
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // f
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
    }),
    // g
    makeBlockDigit(.{
        .{ 0, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 0, 1, 1, 1, 0 },
    }),
    // h
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // i
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // j
    makeBlockDigit(.{
        .{ 0, 0, 1, 1, 1 },
        .{ 0, 0, 0, 1, 0 },
        .{ 0, 0, 0, 1, 0 },
        .{ 1, 0, 0, 1, 0 },
        .{ 0, 1, 1, 0, 0 },
    }),
    // k
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 1, 0 },
        .{ 1, 1, 1, 0, 0 },
        .{ 1, 0, 0, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // l
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
    }),
    // m
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 0, 1, 1 },
        .{ 1, 0, 1, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // n
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 0, 0, 1 },
        .{ 1, 0, 1, 0, 1 },
        .{ 1, 0, 0, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // o
    makeBlockDigit(.{
        .{ 0, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 0, 1, 1, 1, 0 },
    }),
    // p
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 0 },
        .{ 1, 0, 0, 0, 0 },
    }),
    // q
    makeBlockDigit(.{
        .{ 0, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 1, 0 },
        .{ 0, 1, 1, 0, 1 },
    }),
    // r
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 0 },
        .{ 1, 0, 0, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // s
    makeBlockDigit(.{
        .{ 0, 1, 1, 1, 1 },
        .{ 1, 0, 0, 0, 0 },
        .{ 0, 1, 1, 1, 0 },
        .{ 0, 0, 0, 0, 1 },
        .{ 1, 1, 1, 1, 0 },
    }),
    // t
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
    }),
    // u
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 0, 1, 1, 1, 0 },
    }),
    // v
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 0, 1, 0, 1, 0 },
        .{ 0, 0, 1, 0, 0 },
    }),
    // w
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 0, 0, 1 },
        .{ 1, 0, 1, 0, 1 },
        .{ 1, 1, 0, 1, 1 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // x
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 0, 1, 0, 1, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 1, 0, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
    }),
    // y
    makeBlockDigit(.{
        .{ 1, 0, 0, 0, 1 },
        .{ 0, 1, 0, 1, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 0, 1, 0, 0 },
    }),
    // z
    makeBlockDigit(.{
        .{ 1, 1, 1, 1, 1 },
        .{ 0, 0, 0, 1, 0 },
        .{ 0, 0, 1, 0, 0 },
        .{ 0, 1, 0, 0, 0 },
        .{ 1, 1, 1, 1, 1 },
    }),
};

/// Get the pixel map for a character
pub fn getPixelMap(char: u8) ?PixelMap {
    if (char >= '0' and char <= '9') {
        return BLOCK_DIGITS[char - '0'];
    }
    if (char >= 'a' and char <= 'z') {
        return BLOCK_LETTERS[char - 'a'];
    }
    if (char >= 'A' and char <= 'Z') {
        return BLOCK_LETTERS[char - 'A'];
    }
    return null;
}

/// Render a character using quadrant blocks for higher resolution
/// Returns the character to display at cell (cx, cy)
pub fn getQuadrantChar(char: u8, cx: u8, cy: u8) u21 {
    const pmap = getPixelMap(char) orelse return ' ';
    const bits = pmap.getQuadrant(cx, cy);
    return Block.fromQuadrant(bits);
}

// Legacy compatibility
pub const WIDTH: u16 = 5;
pub const HEIGHT: u16 = 5;
pub const BigDigit = [5][5]u21;

/// Legacy: Get digit as 5x5 array of characters (full blocks)
pub fn getDigit(char: u8) ?*const BigDigit {
    const idx: usize = blk: {
        if (char >= '1' and char <= '9') break :blk char - '0';
        if (char == '0') break :blk 0;
        if (char >= 'a' and char <= 'z') break :blk 10 + (char - 'a');
        if (char >= 'A' and char <= 'Z') break :blk 10 + (char - 'A');
        return null;
    };

    const Storage = struct {
        var cache: [36]BigDigit = undefined;
        var initialized: [36]bool = .{false} ** 36;
    };

    if (idx >= 36) return null;

    if (!Storage.initialized[idx]) {
        const pmap = if (idx < 10) BLOCK_DIGITS[idx] else BLOCK_LETTERS[idx - 10];
        for (0..5) |y| {
            for (0..5) |x| {
                Storage.cache[idx][y][x] = if (pmap.get(@intCast(x), @intCast(y))) Block.FULL else ' ';
            }
        }
        Storage.initialized[idx] = true;
    }

    return &Storage.cache[idx];
}
