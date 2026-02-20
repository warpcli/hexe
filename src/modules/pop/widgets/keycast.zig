const pokemon = @import("pokemon.zig");
const overlay_keycast = @import("../overlay/keycast.zig");

/// Keycast configuration for widget placement and behavior.
pub const KeycastConfig = struct {
    enabled: bool = false,
    position: pokemon.Position = .bottomright,
    duration_ms: i64 = 2000,
    max_entries: u8 = 8,
    grouping_timeout_ms: i64 = 500,
};

pub const KeycastEntry = overlay_keycast.KeycastEntry;
pub const KeycastState = overlay_keycast.KeycastState;
