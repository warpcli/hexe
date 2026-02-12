const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const config_builder = @import("config_builder.zig");
const ConfigBuilder = config_builder.ConfigBuilder;
const config = @import("config.zig");

/// Registry key for storing ConfigBuilder pointer
const BUILDER_REGISTRY_KEY = "_hexe_config_builder";

/// Store ConfigBuilder pointer in Lua registry
pub fn storeConfigBuilder(lua: *Lua, builder: *ConfigBuilder) !void {
    lua.pushLightUserdata(builder);
    lua.setField(zlua.registry_index, BUILDER_REGISTRY_KEY);
}

/// Retrieve ConfigBuilder pointer from Lua registry
pub fn getConfigBuilder(lua: *Lua) ?*ConfigBuilder {
    _ = lua.getField(zlua.registry_index, BUILDER_REGISTRY_KEY);
    defer lua.pop(1);

    if (lua.typeOf(-1) != .light_userdata) {
        return null;
    }

    const ptr = lua.toUserdata(?*ConfigBuilder, -1) catch return null;
    return ptr;
}

/// Helper to get MuxConfigBuilder, creating it if needed
pub fn getMuxBuilder(lua: *Lua) !*config_builder.MuxConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.mux == null) {
        builder.mux = try config_builder.MuxConfigBuilder.init(builder.allocator);
    }

    return builder.mux.?;
}

/// Helper to get SesConfigBuilder, creating it if needed
pub fn getSesBuilder(lua: *Lua) !*config_builder.SesConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.ses == null) {
        builder.ses = try config_builder.SesConfigBuilder.init(builder.allocator);
    }

    return builder.ses.?;
}

/// Helper to get ShpConfigBuilder, creating it if needed
pub fn getShpBuilder(lua: *Lua) !*config_builder.ShpConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.shp == null) {
        builder.shp = try config_builder.ShpConfigBuilder.init(builder.allocator);
    }

    return builder.shp.?;
}

/// Helper to get PopConfigBuilder, creating it if needed
pub fn getPopBuilder(lua: *Lua) !*config_builder.PopConfigBuilder {
    const builder = getConfigBuilder(lua) orelse return error.NoConfigBuilder;

    if (builder.pop == null) {
        builder.pop = try config_builder.PopConfigBuilder.init(builder.allocator);
    }

    return builder.pop.?;
}

// ===== Parsing Helpers =====

/// Parse a key string into BindKey
fn parseKeyString(key_str: []const u8) ?config.Config.BindKey {
    if (key_str.len == 1) return .{ .char = key_str[0] };
    if (std.mem.eql(u8, key_str, "space")) return .space;
    if (std.mem.eql(u8, key_str, "up")) return .up;
    if (std.mem.eql(u8, key_str, "down")) return .down;
    if (std.mem.eql(u8, key_str, "left")) return .left;
    if (std.mem.eql(u8, key_str, "right")) return .right;
    return null;
}

/// Result of parsing a key array
pub const ParsedKey = struct {
    mods: u8, // Bitmask of modifiers
    key: config.Config.BindKey,
};

/// Parse Lua array of keys into mods + key
/// Format: { hx.key.ctrl, hx.key.alt, hx.key.q }
/// Modifiers are prefixed with "mod:", actual keys are not
pub fn parseKeyArray(lua: *Lua, table_idx: i32) ?ParsedKey {
    if (lua.typeOf(table_idx) != .table) return null;

    var mods: u8 = 0;
    var key: ?config.Config.BindKey = null;

    const len = lua.rawLen(table_idx);
    var i: i32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(table_idx, i);
        defer lua.pop(1);

        const elem = lua.toString(-1) catch continue;

        // Check if it's a modifier (prefixed with "mod:")
        if (std.mem.startsWith(u8, elem, "mod:")) {
            const mod_name = elem[4..];
            if (std.mem.eql(u8, mod_name, "ctrl")) {
                mods |= 2;
            } else if (std.mem.eql(u8, mod_name, "alt")) {
                mods |= 1;
            } else if (std.mem.eql(u8, mod_name, "shift")) {
                mods |= 4;
            } else if (std.mem.eql(u8, mod_name, "super")) {
                mods |= 8;
            }
        } else {
            // It's a key
            if (parseKeyString(elem)) |k| {
                key = k;
            }
        }
    }

    if (key) |k| {
        return ParsedKey{ .mods = mods, .key = k };
    }

    return null;
}

/// Parse action string into BindAction
/// Handles simple actions like "mux.quit", "tab.new", etc.
fn parseSimpleAction(action_str: []const u8) ?config.Config.BindAction {
    if (std.mem.eql(u8, action_str, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action_str, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action_str, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action_str, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action_str, "pane.close")) return .pane_close;
    if (std.mem.eql(u8, action_str, "pane.select_mode")) return .pane_select_mode;
    if (std.mem.eql(u8, action_str, "overlay.keycast_toggle")) return .keycast_toggle;
    if (std.mem.eql(u8, action_str, "overlay.sprite_toggle")) return .sprite_toggle;
    if (std.mem.eql(u8, action_str, "split.h")) return .split_h;
    if (std.mem.eql(u8, action_str, "split.v")) return .split_v;
    if (std.mem.eql(u8, action_str, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action_str, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action_str, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action_str, "tab.close")) return .tab_close;
    return null;
}

/// Parse action from Lua (string or table with parameters)
pub fn parseAction(lua: *Lua, idx: i32) ?config.Config.BindAction {
    const action_type = lua.typeOf(idx);

    // Simple string action
    if (action_type == .string) {
        const action_str = lua.toString(idx) catch return null;
        return parseSimpleAction(action_str);
    }

    // Table action with parameters (e.g., {type="focus.move", dir="up"})
    if (action_type == .table) {
        _ = lua.getField(idx, "type");
        defer lua.pop(1);

        const type_str = lua.toString(-1) catch return null;

        // Parametric actions
        if (std.mem.eql(u8, type_str, "split.resize")) {
            _ = lua.getField(idx, "dir");
            defer lua.pop(1);
            const dir_str = lua.toString(-1) catch return null;
            const dir = std.meta.stringToEnum(config.Config.BindKeyKind, dir_str) orelse return null;
            if (dir != .up and dir != .down and dir != .left and dir != .right) return null;
            return .{ .split_resize = dir };
        }

        if (std.mem.eql(u8, type_str, "float.toggle")) {
            _ = lua.getField(idx, "float");
            defer lua.pop(1);
            const float_key = lua.toString(-1) catch return null;
            if (float_key.len != 1) return null;
            return .{ .float_toggle = float_key[0] };
        }

        if (std.mem.eql(u8, type_str, "float.nudge")) {
            _ = lua.getField(idx, "dir");
            defer lua.pop(1);
            const dir_str = lua.toString(-1) catch return null;
            const dir = std.meta.stringToEnum(config.Config.BindKeyKind, dir_str) orelse return null;
            if (dir != .up and dir != .down and dir != .left and dir != .right) return null;
            return .{ .float_nudge = dir };
        }

        if (std.mem.eql(u8, type_str, "focus.move")) {
            _ = lua.getField(idx, "dir");
            defer lua.pop(1);
            const dir_str = lua.toString(-1) catch return null;
            const dir = std.meta.stringToEnum(config.Config.BindKeyKind, dir_str) orelse return null;
            if (dir != .up and dir != .down and dir != .left and dir != .right) return null;
            return .{ .focus_move = dir };
        }

        // Fall back to simple action if type matches
        return parseSimpleAction(type_str);
    }

    return null;
}

// ===== MUX API Functions =====

/// Lua C function: hexe.mux.config.set(key, value)
pub export fn hexe_mux_config_set(L: ?*LuaState) callconv(.C) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get key (arg 1)
    const key = lua.toString(1) catch {
        _ = lua.pushString("config.set: key must be a string");
        lua.raiseError();
    };

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("config.set: failed to get config builder");
        lua.raiseError();
    };

    // Type-based value parsing (arg 2)
    const val_type = lua.typeOf(2);

    // Boolean options
    if (val_type == .boolean) {
        const val = lua.toBoolean(2);
        if (std.mem.eql(u8, key, "confirm_on_exit")) {
            mux.confirm_on_exit = val;
        } else if (std.mem.eql(u8, key, "confirm_on_detach")) {
            mux.confirm_on_detach = val;
        } else if (std.mem.eql(u8, key, "confirm_on_disown")) {
            mux.confirm_on_disown = val;
        } else if (std.mem.eql(u8, key, "confirm_on_close")) {
            mux.confirm_on_close = val;
        } else if (std.mem.eql(u8, key, "winpulse_enabled")) {
            mux.winpulse_enabled = val;
        } else {
            const msg = std.fmt.allocPrint(mux.allocator, "config.set: unknown boolean key '{s}'", .{key}) catch "config.set: unknown key";
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        return 0;
    }

    // Number options
    if (val_type == .number) {
        const val_f64 = lua.toNumber(2) catch {
            _ = lua.pushString("config.set: failed to parse number");
            lua.raiseError();
        };

        if (std.mem.eql(u8, key, "winpulse_duration_ms")) {
            mux.winpulse_duration_ms = @intFromFloat(val_f64);
        } else if (std.mem.eql(u8, key, "winpulse_brighten_factor")) {
            mux.winpulse_brighten_factor = @floatCast(val_f64);
        } else if (std.mem.eql(u8, key, "selection_color")) {
            mux.selection_color = @intFromFloat(val_f64);
        } else if (std.mem.eql(u8, key, "mouse_selection_override_mods")) {
            mux.mouse_selection_override_mods = @intFromFloat(val_f64);
        } else {
            const msg = std.fmt.allocPrint(mux.allocator, "config.set: unknown number key '{s}'", .{key}) catch "config.set: unknown key";
            _ = lua.pushString(msg);
            lua.raiseError();
        }
        return 0;
    }

    // Unknown type
    _ = lua.pushString("config.set: value must be boolean or number");
    lua.raiseError();
}

/// Lua C function: hexe.mux.config.setup(opts)
pub export fn hexe_mux_config_setup(L: ?*LuaState) callconv(.C) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("config.setup: argument must be a table");
        lua.raiseError();
    }

    // Iterate table and call set for each key
    lua.pushNil(); // First key
    while (lua.next(1)) {
        // Stack: table, key, value
        // Duplicate key for next iteration (next() pops the key)
        lua.pushValue(-2);

        // Now stack: table, key, value, key
        // Call set(key, value)
        lua.pushValue(-2); // Push value
        // Stack: table, key, value, key, value
        _ = hexe_mux_config_set(L);

        // Pop value (key is already popped by next())
        lua.pop(1);
    }

    return 0;
}
