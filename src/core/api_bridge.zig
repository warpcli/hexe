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

    const ptr = lua.toPointer(-1) catch return null;
    const addr = @intFromPtr(ptr);
    return @ptrFromInt(addr);
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

/// Parse a layout pane from Lua table
fn parseLayoutPane(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config.LayoutPaneDef {
    var pane = config.LayoutPaneDef{};

    // Parse cwd
    _ = lua.getField(idx, "cwd");
    if (lua.typeOf(-1) == .string) {
        const cwd_str = lua.toString(-1) catch null;
        if (cwd_str) |c| {
            pane.cwd = allocator.dupe(u8, c) catch null;
        }
    }
    lua.pop(1);

    // Parse command
    _ = lua.getField(idx, "command");
    if (lua.typeOf(-1) == .string) {
        const cmd_str = lua.toString(-1) catch null;
        if (cmd_str) |c| {
            pane.command = allocator.dupe(u8, c) catch null;
        }
    }
    lua.pop(1);

    return pane;
}

/// Parse a layout split recursively from Lua table
fn parseLayoutSplit(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?*config.LayoutSplitDef {
    // Check if this is a split (has array elements) or a pane
    const array_len = lua.rawLen(idx);

    if (array_len >= 2) {
        // This is a split with children
        // Parse dir
        _ = lua.getField(idx, "dir");
        const dir_str = lua.toString(-1) catch "h";
        const dir = allocator.dupe(u8, dir_str) catch return null;
        lua.pop(1);

        // Parse ratio
        _ = lua.getField(idx, "ratio");
        const ratio_f64 = if (lua.typeOf(-1) == .number)
            lua.toNumber(-1) catch 0.5
        else
            0.5;
        const ratio: f32 = @floatCast(ratio_f64);
        lua.pop(1);

        // Parse first child
        _ = lua.rawGetIndex(idx, 1);
        const first_child = parseLayoutSplit(lua, -1, allocator) orelse {
            lua.pop(1);
            allocator.free(dir);
            return null;
        };
        lua.pop(1);

        // Parse second child
        _ = lua.rawGetIndex(idx, 2);
        const second_child = parseLayoutSplit(lua, -1, allocator) orelse {
            lua.pop(1);
            first_child.deinit(allocator);
            allocator.destroy(first_child);
            allocator.free(dir);
            return null;
        };
        lua.pop(1);

        // Create split
        const split = allocator.create(config.LayoutSplitDef) catch {
            first_child.deinit(allocator);
            allocator.destroy(first_child);
            second_child.deinit(allocator);
            allocator.destroy(second_child);
            allocator.free(dir);
            return null;
        };

        split.* = .{
            .split = .{
                .dir = dir,
                .ratio = ratio,
                .first = first_child,
                .second = second_child,
            },
        };

        return split;
    } else {
        // This is a pane
        const pane = parseLayoutPane(lua, idx, allocator) orelse return null;
        const split = allocator.create(config.LayoutSplitDef) catch return null;
        split.* = .{ .pane = pane };
        return split;
    }
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
pub fn hexe_mux_config_set(L: ?*LuaState) callconv(.c) c_int {
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
pub export fn hexe_mux_config_setup(L: ?*LuaState) callconv(.c) c_int {
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

/// Lua C function: hexe.mux.keymap.set(keys, action, opts)
pub export fn hexe_mux_keymap_set(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("keymap.set: failed to get config builder");
        lua.raiseError();
    };

    // Parse keys array (arg 1)
    const parsed_key = parseKeyArray(lua, 1) orelse {
        _ = lua.pushString("keymap.set: invalid key array");
        lua.raiseError();
    };

    // Parse action (arg 2) - can be nil for passthrough_only mode
    var action: config.Config.BindAction = .mux_quit; // placeholder
    var action_found = false;

    if (lua.typeOf(2) != .nil) {
        action = parseAction(lua, 2) orelse {
            _ = lua.pushString("keymap.set: invalid action");
            lua.raiseError();
        };
        action_found = true;
    }

    // Parse opts table (arg 3, optional)
    var on: config.Config.BindWhen = .press;
    var mode: config.Config.BindMode = .act_and_consume;
    var hold_ms: ?i64 = null;
    const when: ?config.WhenDef = null;

    if (lua.typeOf(3) == .table) {
        // Parse "on" field
        _ = lua.getField(3, "on");
        if (lua.typeOf(-1) == .string) {
            const on_str = lua.toString(-1) catch "press";
            on = std.meta.stringToEnum(config.Config.BindWhen, on_str) orelse .press;
        }
        lua.pop(1);

        // Parse "mode" field
        _ = lua.getField(3, "mode");
        if (lua.typeOf(-1) == .string) {
            const mode_str = lua.toString(-1) catch "act_and_consume";
            mode = std.meta.stringToEnum(config.Config.BindMode, mode_str) orelse .act_and_consume;
        }
        lua.pop(1);

        // Parse "hold_ms" field
        _ = lua.getField(3, "hold_ms");
        if (lua.typeOf(-1) == .number) {
            const val = lua.toNumber(-1) catch 0;
            hold_ms = @intFromFloat(val);
        }
        lua.pop(1);

        // TODO: Parse "when" field (complex, skip for now)
    }

    // Validate action is present unless mode is passthrough_only
    if (!action_found and mode != .passthrough_only) {
        _ = lua.pushString("keymap.set: action required unless mode is passthrough_only");
        lua.raiseError();
    }

    // Create bind
    const bind = config.Config.Bind{
        .on = on,
        .mods = parsed_key.mods,
        .key = parsed_key.key,
        .action = action,
        .when = when,
        .mode = mode,
        .hold_ms = hold_ms,
    };

    // Append to binds list
    mux.binds.append(mux.allocator, bind) catch {
        _ = lua.pushString("keymap.set: failed to append bind");
        lua.raiseError();
    };

    return 0;
}

/// Lua C function: hexe.mux.float.set_defaults(opts)
pub export fn hexe_mux_float_set_defaults(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("float.set_defaults: argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("float.set_defaults: failed to get config builder");
        lua.raiseError();
    };

    // Initialize float_defaults if not already
    if (mux.float_defaults == null) {
        mux.float_defaults = .{};
    }

    // Parse size table
    _ = lua.getField(1, "size");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "width");
        if (lua.typeOf(-1) == .number) {
            const w = lua.toNumber(-1) catch 0;
            mux.float_defaults.?.width_percent = @intFromFloat(w);
        }
        lua.pop(1);

        _ = lua.getField(-1, "height");
        if (lua.typeOf(-1) == .number) {
            const h = lua.toNumber(-1) catch 0;
            mux.float_defaults.?.height_percent = @intFromFloat(h);
        }
        lua.pop(1);
    }
    lua.pop(1);

    // Parse padding table
    _ = lua.getField(1, "padding");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "x");
        if (lua.typeOf(-1) == .number) {
            const x = lua.toNumber(-1) catch 0;
            mux.float_defaults.?.padding_x = @intFromFloat(x);
        }
        lua.pop(1);

        _ = lua.getField(-1, "y");
        if (lua.typeOf(-1) == .number) {
            const y = lua.toNumber(-1) catch 0;
            mux.float_defaults.?.padding_y = @intFromFloat(y);
        }
        lua.pop(1);
    }
    lua.pop(1);

    // Parse color table
    _ = lua.getField(1, "color");
    if (lua.typeOf(-1) == .table) {
        var color = config.BorderColor{};
        _ = lua.getField(-1, "active");
        if (lua.typeOf(-1) == .number) {
            const a = lua.toNumber(-1) catch 0;
            color.active = @intFromFloat(a);
        }
        lua.pop(1);

        _ = lua.getField(-1, "passive");
        if (lua.typeOf(-1) == .number) {
            const p = lua.toNumber(-1) catch 0;
            color.passive = @intFromFloat(p);
        }
        lua.pop(1);

        mux.float_defaults.?.color = color;
    }
    lua.pop(1);

    // TODO: Parse attributes, style (more complex, skip for now)

    return 0;
}

/// Lua C function: hexe.mux.float.define(key, opts)
pub export fn hexe_mux_float_define(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get key (arg 1)
    const key_str = lua.toString(1) catch {
        _ = lua.pushString("float.define: key must be a string");
        lua.raiseError();
    };
    if (key_str.len != 1) {
        _ = lua.pushString("float.define: key must be a single character");
        lua.raiseError();
    }
    const key = key_str[0];

    // Arg 2 must be a table
    if (lua.typeOf(2) != .table) {
        _ = lua.pushString("float.define: second argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("float.define: failed to get config builder");
        lua.raiseError();
    };

    // Create FloatDef
    var float_def = config.FloatDef{
        .key = key,
        .command = null,
        .title = null,
    };

    // Parse command
    _ = lua.getField(2, "command");
    if (lua.typeOf(-1) == .string) {
        const cmd = lua.toString(-1) catch null;
        if (cmd) |c| {
            float_def.command = mux.allocator.dupe(u8, c) catch null;
        }
    }
    lua.pop(1);

    // Parse title
    _ = lua.getField(2, "title");
    if (lua.typeOf(-1) == .string) {
        const t = lua.toString(-1) catch null;
        if (t) |title_str| {
            float_def.title = mux.allocator.dupe(u8, title_str) catch null;
        }
    }
    lua.pop(1);

    // TODO: Parse size, position, padding, attributes, color, style

    // Append to floats list
    mux.floats.append(mux.allocator, float_def) catch {
        _ = lua.pushString("float.define: failed to append float");
        lua.raiseError();
    };

    return 0;
}

/// Lua C function: hexe.mux.tabs.add_segment(position, segment)
pub export fn hexe_mux_tabs_add_segment(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get position (arg 1)
    const position = lua.toString(1) catch {
        _ = lua.pushString("tabs.add_segment: position must be a string");
        lua.raiseError();
    };

    // Arg 2 must be a table
    if (lua.typeOf(2) != .table) {
        _ = lua.pushString("tabs.add_segment: second argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("tabs.add_segment: failed to get config builder");
        lua.raiseError();
    };

    // Parse segment fields
    _ = lua.getField(2, "name");
    const name = lua.toString(-1) catch {
        _ = lua.pushString("tabs.add_segment: segment must have a 'name' field");
        lua.raiseError();
    };
    const name_copy = mux.allocator.dupe(u8, name) catch {
        _ = lua.pushString("tabs.add_segment: failed to allocate name");
        lua.raiseError();
    };
    lua.pop(1);

    // Create basic segment (simplified for now)
    const segment = config.Segment{
        .name = name_copy,
        .priority = 50, // default
        // TODO: Parse outputs, command, when, etc.
    };

    // Append to appropriate list
    if (std.mem.eql(u8, position, "left")) {
        mux.tabs_config.segments_left.append(mux.allocator, segment) catch {
            _ = lua.pushString("tabs.add_segment: failed to append segment");
            lua.raiseError();
        };
    } else if (std.mem.eql(u8, position, "center")) {
        mux.tabs_config.segments_center.append(mux.allocator, segment) catch {
            _ = lua.pushString("tabs.add_segment: failed to append segment");
            lua.raiseError();
        };
    } else if (std.mem.eql(u8, position, "right")) {
        mux.tabs_config.segments_right.append(mux.allocator, segment) catch {
            _ = lua.pushString("tabs.add_segment: failed to append segment");
            lua.raiseError();
        };
    } else {
        _ = lua.pushString("tabs.add_segment: position must be 'left', 'center', or 'right'");
        lua.raiseError();
    }

    return 0;
}

/// Lua C function: hexe.mux.tabs.set_status(enabled)
pub export fn hexe_mux_tabs_set_status(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get enabled (arg 1)
    if (lua.typeOf(1) != .boolean) {
        _ = lua.pushString("tabs.set_status: argument must be a boolean");
        lua.raiseError();
    }
    const enabled = lua.toBoolean(1);

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("tabs.set_status: failed to get config builder");
        lua.raiseError();
    };

    mux.tabs_config.status_enabled = enabled;

    return 0;
}

/// Lua C function: hexe.mux.splits.setup(opts)
pub export fn hexe_mux_splits_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("splits.setup: argument must be a table");
        lua.raiseError();
    }

    // Get MuxConfigBuilder
    const mux = getMuxBuilder(lua) catch {
        _ = lua.pushString("splits.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse color table
    _ = lua.getField(1, "color");
    if (lua.typeOf(-1) == .table) {
        var color = config.BorderColor{};
        _ = lua.getField(-1, "active");
        if (lua.typeOf(-1) == .number) {
            const a = lua.toNumber(-1) catch 0;
            color.active = @intFromFloat(a);
        }
        lua.pop(1);

        _ = lua.getField(-1, "passive");
        if (lua.typeOf(-1) == .number) {
            const p = lua.toNumber(-1) catch 0;
            color.passive = @intFromFloat(p);
        }
        lua.pop(1);

        mux.splits_config.color = color;
    }
    lua.pop(1);

    // TODO: Parse separator_v, separator_h, style (Unicode parsing needed)

    return 0;
}

// ===== SES API Functions =====

/// Lua C function: hexe.ses.layout.define(name, opts)
pub export fn hexe_ses_layout_define(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Get name (arg 1)
    const name_str = lua.toString(1) catch {
        _ = lua.pushString("layout.define: name must be a string");
        lua.raiseError();
    };

    // Arg 2 must be a table
    if (lua.typeOf(2) != .table) {
        _ = lua.pushString("layout.define: second argument must be a table");
        lua.raiseError();
    }

    // Get SesConfigBuilder
    const ses = getSesBuilder(lua) catch {
        _ = lua.pushString("layout.define: failed to get config builder");
        lua.raiseError();
    };

    const name = ses.allocator.dupe(u8, name_str) catch {
        _ = lua.pushString("layout.define: failed to allocate name");
        lua.raiseError();
    };

    // Parse enabled
    _ = lua.getField(2, "enabled");
    const enabled = if (lua.typeOf(-1) == .boolean)
        lua.toBoolean(-1)
    else
        false;
    lua.pop(1);

    // Parse tabs array
    var tabs = std.ArrayList(config.LayoutTabDef){};
    _ = lua.getField(2, "tabs");
    if (lua.typeOf(-1) == .table) {
        const tabs_len = lua.rawLen(-1);
        var i: i32 = 1;
        while (i <= tabs_len) : (i += 1) {
            _ = lua.rawGetIndex(-1, i);
            if (lua.typeOf(-1) == .table) {
                // Parse tab
                _ = lua.getField(-1, "name");
                const tab_name_str = lua.toString(-2) catch {
                    lua.pop(2); // pop name and tab
                    continue;
                };
                const tab_name = ses.allocator.dupe(u8, tab_name_str) catch {
                    lua.pop(2);
                    continue;
                };
                lua.pop(1); // pop name

                // Parse root split
                _ = lua.getField(-1, "root");
                const root = if (lua.typeOf(-1) == .table)
                    parseLayoutSplit(lua, -1, ses.allocator)
                else
                    null;
                lua.pop(1); // pop root

                const tab = config.LayoutTabDef{
                    .name = tab_name,
                    .enabled = true,
                    .root = if (root) |r| r.* else null,
                };
                tabs.append(ses.allocator, tab) catch {};
            }
            lua.pop(1); // pop tab
        }
    }
    lua.pop(1); // pop tabs array

    // Create layout
    const layout = config.LayoutDef{
        .name = name,
        .enabled = enabled,
        .tabs = tabs.toOwnedSlice(ses.allocator) catch &[_]config.LayoutTabDef{},
        .floats = &[_]config.LayoutFloatDef{}, // TODO: Parse floats
    };

    // Append to layouts
    ses.layouts.append(ses.allocator, layout) catch {
        _ = lua.pushString("layout.define: failed to append layout");
        lua.raiseError();
    };

    return 0;
}

/// Lua C function: hexe.ses.session.setup(opts)
pub export fn hexe_ses_session_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("session.setup: argument must be a table");
        lua.raiseError();
    }

    // Get SesConfigBuilder
    const ses = getSesBuilder(lua) catch {
        _ = lua.pushString("session.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse auto_restore
    _ = lua.getField(1, "auto_restore");
    if (lua.typeOf(-1) == .boolean) {
        ses.auto_restore = lua.toBoolean(-1);
    }
    lua.pop(1);

    // Parse save_on_detach
    _ = lua.getField(1, "save_on_detach");
    if (lua.typeOf(-1) == .boolean) {
        ses.save_on_detach = lua.toBoolean(-1);
    }
    lua.pop(1);

    return 0;
}

// ============================================================================
// Section 3: SHP (Shell Prompt) C API
// ============================================================================

/// Helper: Parse output definition from a table
fn parseOutputDef(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config_builder.ShpConfigBuilder.OutputDef {
    if (lua.typeOf(idx) != .table) return null;

    var style: ?[]const u8 = null;
    var format: ?[]const u8 = null;

    _ = lua.getField(idx, "style");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch return null;
        style = allocator.dupe(u8, s) catch return null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "format");
    if (lua.typeOf(-1) == .string) {
        const f = lua.toString(-1) catch return null;
        format = allocator.dupe(u8, f) catch return null;
    }
    lua.pop(1);

    if (style == null or format == null) return null;

    return config_builder.ShpConfigBuilder.OutputDef{
        .style = style.?,
        .format = format.?,
    };
}

/// Helper: Parse segment definition from a table
fn parseSegmentDef(lua: *Lua, idx: i32, allocator: std.mem.Allocator) ?config_builder.ShpConfigBuilder.SegmentDef {
    if (lua.typeOf(idx) != .table) return null;

    var name: ?[]const u8 = null;
    var priority: i64 = 50; // default priority
    var outputs = std.ArrayList(config_builder.ShpConfigBuilder.OutputDef){};
    var command: ?[]const u8 = null;
    var when: ?config.WhenDef = null;

    // Parse name (required)
    _ = lua.getField(idx, "name");
    if (lua.typeOf(-1) == .string) {
        const n = lua.toString(-1) catch return null;
        name = allocator.dupe(u8, n) catch return null;
    }
    lua.pop(1);

    if (name == null) return null;

    // Parse priority (optional)
    _ = lua.getField(idx, "priority");
    if (lua.typeOf(-1) == .number) {
        priority = lua.toInteger(-1) catch 50;
    }
    lua.pop(1);

    // Parse outputs (required array)
    _ = lua.getField(idx, "outputs");
    if (lua.typeOf(-1) == .table) {
        const n = lua.rawLen(-1);
        var i: i32 = 1;
        while (i <= n) : (i += 1) {
            _ = lua.rawGetIndex(-1, i);
            if (parseOutputDef(lua, -1, allocator)) |output| {
                outputs.append(allocator, output) catch {};
            }
            lua.pop(1);
        }
    }
    lua.pop(1);

    // Parse command (optional)
    _ = lua.getField(idx, "command");
    if (lua.typeOf(-1) == .string) {
        const c = lua.toString(-1) catch null;
        if (c) |cmd| {
            command = allocator.dupe(u8, cmd) catch null;
        }
    }
    lua.pop(1);

    // Parse when (optional) - simplified for now
    _ = lua.getField(idx, "when");
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "env");
        if (lua.typeOf(-1) == .string) {
            const env = lua.toString(-1) catch null;
            if (env) |e| {
                const env_copy = allocator.dupe(u8, e) catch null;
                if (env_copy) |ec| {
                    when = config.WhenDef{ .env = ec };
                }
            }
        }
        lua.pop(1);
    }
    lua.pop(1);

    return config_builder.ShpConfigBuilder.SegmentDef{
        .name = name.?,
        .priority = priority,
        .outputs = outputs.toOwnedSlice(allocator) catch &[_]config_builder.ShpConfigBuilder.OutputDef{},
        .command = command,
        .when = when,
    };
}

/// Lua C function: hexe.shp.prompt.left(segments)
pub export fn hexe_shp_prompt_left(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table (array of segments)
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("prompt.left: argument must be a table");
        lua.raiseError();
    }

    // Get ShpConfigBuilder
    const shp = getShpBuilder(lua) catch {
        _ = lua.pushString("prompt.left: failed to get config builder");
        lua.raiseError();
    };

    // Parse segments array
    const n = lua.rawLen(1);
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        _ = lua.rawGetIndex(1, i);
        if (parseSegmentDef(lua, -1, shp.allocator)) |segment| {
            shp.left_segments.append(shp.allocator, segment) catch {};
        }
        lua.pop(1);
    }

    return 0;
}

/// Lua C function: hexe.shp.prompt.right(segments)
pub export fn hexe_shp_prompt_right(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1 must be a table (array of segments)
    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("prompt.right: argument must be a table");
        lua.raiseError();
    }

    // Get ShpConfigBuilder
    const shp = getShpBuilder(lua) catch {
        _ = lua.pushString("prompt.right: failed to get config builder");
        lua.raiseError();
    };

    // Parse segments array
    const n = lua.rawLen(1);
    var i: i32 = 1;
    while (i <= n) : (i += 1) {
        _ = lua.rawGetIndex(1, i);
        if (parseSegmentDef(lua, -1, shp.allocator)) |segment| {
            shp.right_segments.append(shp.allocator, segment) catch {};
        }
        lua.pop(1);
    }

    return 0;
}

/// Lua C function: hexe.shp.prompt.add(side, segment)
pub export fn hexe_shp_prompt_add(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    // Arg 1: side (string: "left" or "right")
    // Arg 2: segment (table)
    if (lua.typeOf(1) != .string or lua.typeOf(2) != .table) {
        _ = lua.pushString("prompt.add: arguments must be (string, table)");
        lua.raiseError();
    }

    const side = lua.toString(1) catch {
        _ = lua.pushString("prompt.add: invalid side string");
        lua.raiseError();
    };

    // Get ShpConfigBuilder
    const shp = getShpBuilder(lua) catch {
        _ = lua.pushString("prompt.add: failed to get config builder");
        lua.raiseError();
    };

    // Parse segment
    if (parseSegmentDef(lua, 2, shp.allocator)) |segment| {
        if (std.mem.eql(u8, side, "left")) {
            shp.left_segments.append(shp.allocator, segment) catch {};
        } else if (std.mem.eql(u8, side, "right")) {
            shp.right_segments.append(shp.allocator, segment) catch {};
        } else {
            _ = lua.pushString("prompt.add: side must be 'left' or 'right'");
            lua.raiseError();
        }
    }

    return 0;
}

// ============================================================================
// Section 4: POP (Popups & Overlays) C API
// ============================================================================

/// Helper: Parse notification style from table
fn parseNotificationStyle(lua: *Lua, idx: i32, allocator: std.mem.Allocator) config_builder.PopConfigBuilder.NotificationStyleDef {
    var style = config_builder.PopConfigBuilder.NotificationStyleDef{};

    _ = lua.getField(idx, "fg");
    if (lua.typeOf(-1) == .number) style.fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bg");
    if (lua.typeOf(-1) == .number) style.bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "padding_x");
    if (lua.typeOf(-1) == .number) style.padding_x = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "padding_y");
    if (lua.typeOf(-1) == .number) style.padding_y = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "offset");
    if (lua.typeOf(-1) == .number) style.offset = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "alignment");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        style.alignment = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "duration_ms");
    if (lua.typeOf(-1) == .number) style.duration_ms = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    return style;
}

/// Lua C function: hexe.pop.notify.setup(opts)
pub fn hexe_pop_notify_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("notify.setup: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("notify.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse carrier realm
    _ = lua.getField(1, "carrier");
    if (lua.typeOf(-1) == .table) {
        pop.carrier_notification = parseNotificationStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    // Parse pane realm
    _ = lua.getField(1, "pane");
    if (lua.typeOf(-1) == .table) {
        pop.pane_notification = parseNotificationStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    return 0;
}

/// Helper: Parse confirm style from table
fn parseConfirmStyle(lua: *Lua, idx: i32, allocator: std.mem.Allocator) config_builder.PopConfigBuilder.ConfirmStyleDef {
    var style = config_builder.PopConfigBuilder.ConfirmStyleDef{};

    _ = lua.getField(idx, "fg");
    if (lua.typeOf(-1) == .number) style.fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bg");
    if (lua.typeOf(-1) == .number) style.bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "padding_x");
    if (lua.typeOf(-1) == .number) style.padding_x = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "padding_y");
    if (lua.typeOf(-1) == .number) style.padding_y = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "yes_label");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        style.yes_label = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(idx, "no_label");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        style.no_label = allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    return style;
}

/// Lua C function: hexe.pop.confirm.setup(opts)
pub fn hexe_pop_confirm_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("confirm.setup: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("confirm.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse carrier realm
    _ = lua.getField(1, "carrier");
    if (lua.typeOf(-1) == .table) {
        pop.carrier_confirm = parseConfirmStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    // Parse pane realm
    _ = lua.getField(1, "pane");
    if (lua.typeOf(-1) == .table) {
        pop.pane_confirm = parseConfirmStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    return 0;
}

/// Helper: Parse choose style from table
fn parseChooseStyle(lua: *Lua, idx: i32, allocator: std.mem.Allocator) config_builder.PopConfigBuilder.ChooseStyleDef {
    _ = allocator;
    var style = config_builder.PopConfigBuilder.ChooseStyleDef{};

    _ = lua.getField(idx, "fg");
    if (lua.typeOf(-1) == .number) style.fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bg");
    if (lua.typeOf(-1) == .number) style.bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "highlight_fg");
    if (lua.typeOf(-1) == .number) style.highlight_fg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "highlight_bg");
    if (lua.typeOf(-1) == .number) style.highlight_bg = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "bold");
    if (lua.typeOf(-1) == .boolean) style.bold = lua.toBoolean(-1);
    lua.pop(1);

    _ = lua.getField(idx, "padding_x");
    if (lua.typeOf(-1) == .number) style.padding_x = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "padding_y");
    if (lua.typeOf(-1) == .number) style.padding_y = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    _ = lua.getField(idx, "visible_count");
    if (lua.typeOf(-1) == .number) style.visible_count = @intCast(lua.toInteger(-1) catch 0);
    lua.pop(1);

    return style;
}

/// Lua C function: hexe.pop.choose.setup(opts)
pub fn hexe_pop_choose_setup(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("choose.setup: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("choose.setup: failed to get config builder");
        lua.raiseError();
    };

    // Parse carrier realm
    _ = lua.getField(1, "carrier");
    if (lua.typeOf(-1) == .table) {
        pop.carrier_choose = parseChooseStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    // Parse pane realm
    _ = lua.getField(1, "pane");
    if (lua.typeOf(-1) == .table) {
        pop.pane_choose = parseChooseStyle(lua, -1, pop.allocator);
    }
    lua.pop(1);

    return 0;
}

/// Lua C function: hexe.pop.widgets.pokemon(opts)
pub fn hexe_pop_widgets_pokemon(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("widgets.pokemon: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("widgets.pokemon: failed to get config builder");
        lua.raiseError();
    };

    _ = lua.getField(1, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        pop.widgets.pokemon_enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    _ = lua.getField(1, "position");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.pokemon_position = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(1, "shiny_chance");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.pokemon_shiny_chance = @floatCast(lua.toNumber(-1) catch 0.01);
    }
    lua.pop(1);

    return 0;
}

/// Lua C function: hexe.pop.widgets.keycast(opts)
pub fn hexe_pop_widgets_keycast(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("widgets.keycast: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("widgets.keycast: failed to get config builder");
        lua.raiseError();
    };

    _ = lua.getField(1, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        pop.widgets.keycast_enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    _ = lua.getField(1, "position");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.keycast_position = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(1, "duration_ms");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.keycast_duration_ms = lua.toInteger(-1) catch 3000;
    }
    lua.pop(1);

    _ = lua.getField(1, "max_entries");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.keycast_max_entries = @intCast(lua.toInteger(-1) catch 5);
    }
    lua.pop(1);

    _ = lua.getField(1, "grouping_timeout_ms");
    if (lua.typeOf(-1) == .number) {
        pop.widgets.keycast_grouping_timeout_ms = lua.toInteger(-1) catch 500;
    }
    lua.pop(1);

    return 0;
}

/// Lua C function: hexe.pop.widgets.digits(opts)
pub fn hexe_pop_widgets_digits(L: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(L);

    if (lua.typeOf(1) != .table) {
        _ = lua.pushString("widgets.digits: argument must be a table");
        lua.raiseError();
    }

    const pop = getPopBuilder(lua) catch {
        _ = lua.pushString("widgets.digits: failed to get config builder");
        lua.raiseError();
    };

    _ = lua.getField(1, "enabled");
    if (lua.typeOf(-1) == .boolean) {
        pop.widgets.digits_enabled = lua.toBoolean(-1);
    }
    lua.pop(1);

    _ = lua.getField(1, "position");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.digits_position = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    _ = lua.getField(1, "size");
    if (lua.typeOf(-1) == .string) {
        const s = lua.toString(-1) catch "";
        pop.widgets.digits_size = pop.allocator.dupe(u8, s) catch null;
    }
    lua.pop(1);

    return 0;
}
