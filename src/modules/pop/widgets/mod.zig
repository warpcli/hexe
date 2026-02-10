// Widget modules
pub const keycast = @import("keycast.zig");
pub const digits = @import("digits.zig");
pub const pokemon = @import("pokemon.zig");

// Re-export main types
pub const KeycastState = keycast.KeycastState;
pub const KeycastEntry = keycast.KeycastEntry;
pub const KeycastConfig = keycast.KeycastConfig;
pub const PokemonState = pokemon.PokemonState;
pub const PokemonConfig = pokemon.PokemonConfig;
pub const DigitsConfig = digits.DigitsConfig;
pub const Position = pokemon.Position;

/// Widgets configuration
pub const WidgetsConfig = struct {
    pokemon: pokemon.PokemonConfig = .{},
    keycast: keycast.KeycastConfig = .{},
    digits: digits.DigitsConfig = .{},
};
