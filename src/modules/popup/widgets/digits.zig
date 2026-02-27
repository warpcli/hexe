const pokemon = @import("pokemon.zig");
const overlay_digits = @import("../overlay/digits.zig");

/// Digits configuration for widget placement and sizing.
pub const DigitsConfig = struct {
    enabled: bool = false,
    position: pokemon.Position = .topleft,
    size: Size = .small,
};

pub const Size = overlay_digits.Size;
pub const Block = overlay_digits.Block;
pub const PixelMap = overlay_digits.PixelMap;

pub const WIDTH = overlay_digits.WIDTH;
pub const HEIGHT = overlay_digits.HEIGHT;
pub const BigDigit = overlay_digits.BigDigit;

pub const getPixelMap = overlay_digits.getPixelMap;
pub const getQuadrantChar = overlay_digits.getQuadrantChar;
pub const getDigit = overlay_digits.getDigit;
