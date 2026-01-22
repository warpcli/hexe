const std = @import("std");
const posix = std.posix;
const lua_runtime = @import("lua_runtime.zig");
const LuaRuntime = lua_runtime.LuaRuntime;

/// Output definition for status modules (style + format pair)
pub const OutputDef = struct {
    style: []const u8 = "",
    format: []const u8 = "$output",
};

/// Status bar module definition
pub const StatusModule = struct {
    name: []const u8,
    // Priority for width-based hiding (lower = higher priority, stays longer)
    priority: u8 = 50,
    // Array of outputs (each with style + format)
    outputs: []const OutputDef = &[_]OutputDef{},
    // Optional for custom modules
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,
    // For tabs module
    active_style: []const u8 = "bg:1 fg:0",
    inactive_style: []const u8 = "bg:237 fg:250",
    separator: []const u8 = " | ",
    separator_style: []const u8 = "fg:7",
    // For tabs module: what to show as tab title ("name" or "basename")
    tab_title: []const u8 = "basename",
    // For tabs module: arrow decorations (empty string = no arrows)
    left_arrow: []const u8 = "",
    right_arrow: []const u8 = "",
};

/// Status bar config
pub const StatusConfig = struct {
    enabled: bool = true,
    left: []const StatusModule = &[_]StatusModule{},
    center: []const StatusModule = &[_]StatusModule{},
    right: []const StatusModule = &[_]StatusModule{},
};

pub const FloatStylePosition = enum {
    topleft,
    topcenter,
    topright,
    bottomleft,
    bottomcenter,
    bottomright,
};

pub const FloatStyle = struct {
    // Border appearance
    top_left: u21 = 0x256D, // ╭
    top_right: u21 = 0x256E, // ╮
    bottom_left: u21 = 0x2570, // ╰
    bottom_right: u21 = 0x256F, // ╯
    horizontal: u21 = 0x2500, // ─
    vertical: u21 = 0x2502, // │
    // Optional junction characters (not currently used by float border renderer,
    // but supported in config for future flexibility)
    cross: u21 = 0x253C, // ┼
    top_t: u21 = 0x252C, // ┬
    bottom_t: u21 = 0x2534, // ┴
    left_t: u21 = 0x251C, // ├
    right_t: u21 = 0x2524, // ┤

    // Optional drop shadow (palette index). If null, no shadow.
    shadow_color: ?u8 = null,
    // Optional module in border
    position: ?FloatStylePosition = null,
    module: ?StatusModule = null,
};

pub const FloatAttributes = struct {
    /// Hide all other floats on the current tab when this float is shown.
    /// Note: this is one-way today (we don't auto-restore hidden floats).
    exclusive: bool = false,
    /// Create one instance per current working directory.
    /// A per-cwd float is always treated as "global" (not tab-bound).
    per_cwd: bool = false,
    /// Preserve by ses daemon across mux restarts.
    sticky: bool = false,
    /// If true, the float is global (not tab-bound).
    /// If false, it is tab-bound and will be cleaned up when closing that tab.
    global: bool = false,
    /// Kill the float process when hiding it.
    /// Ignored for per-cwd (and typically meaningless for global floats).
    destroy: bool = false,
    /// Run the float command in an isolated pod child (filesystem sandbox + best-effort cgroup limits).
    isolated: bool = false,
};

pub const FloatDef = struct {
    key: u8,
    command: ?[]const u8,
    /// Optional border title text (rendered by mux)
    title: ?[]const u8 = null,
    attributes: FloatAttributes = .{},
    // Per-float overrides (null = use default)
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null, // position as percent (0=left, 50=center, 100=right)
    pos_y: ?u8 = null, // position as percent (0=top, 50=center, 100=bottom)
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    // Border color (per-float override)
    color: ?BorderColor = null,
    // Border style and optional module
    style: ?FloatStyle = null,
};

/// Border color config (active/passive)
pub const BorderColor = struct {
    active: u8 = 1,
    passive: u8 = 237,
};

/// Split border style with junction characters
pub const SplitStyle = struct {
    vertical: u21 = 0x2502, // │
    horizontal: u21 = 0x2500, // ─
    cross: u21 = 0x253C, // ┼
    top_t: u21 = 0x252C, // ┬
    bottom_t: u21 = 0x2534, // ┴
    left_t: u21 = 0x251C, // ├
    right_t: u21 = 0x2524, // ┤
};

/// Splits configuration
pub const SplitsConfig = struct {
    // Keys
    key_split_h: u8 = 'h',
    key_split_v: u8 = 'v',
    // Border color
    color: BorderColor = .{},
    // Simple separator (when no style)
    separator_v: u21 = 0x2502, // │
    separator_h: u21 = 0x2500, // ─
    // Full border style (if set, uses junctions)
    style: ?SplitStyle = null,
};

/// Tabs configuration (includes status bar)
pub const TabsConfig = struct {
    // Keys
    key_new: u8 = 't',
    key_next: u8 = 'n',
    key_prev: u8 = 'p',
    key_close: u8 = 'x',
    key_detach: u8 = 'd',
    // Status bar
    status: StatusConfig = .{},
};

/// Single notification style configuration
pub const NotificationStyleConfig = struct {
    fg: u8 = 0, // foreground color (palette index)
    bg: u8 = 3, // background color (palette index)
    bold: bool = true,
    padding_x: u8 = 1, // horizontal padding inside box
    padding_y: u8 = 0, // vertical padding inside box
    offset: u8 = 1, // vertical offset (MUX: down from top, PANE: up from bottom)
    alignment: []const u8 = "center", // horizontal alignment: left, center, right
    duration_ms: u32 = 3000,
};

/// Dual-realm notification configuration
pub const NotificationConfig = struct {
    // MUX realm - always at TOP of screen
    mux: NotificationStyleConfig = .{
        .offset = 1,
    },
    // PANE realm - always at BOTTOM of each pane
    pane: NotificationStyleConfig = .{
        .offset = 0,
    },
};

/// Panes configuration (placeholder for future use)
pub const PanesConfig = struct {};

pub const Config = struct {
    pub const KeyMod = enum {
        alt,
        ctrl,
        shift,
        super,
    };

    pub const FocusContext = enum {
        any,
        split,
        float,
    };

    pub const BindWhen = enum {
        press,
        release,
        repeat,
        hold,
        double_tap,
    };

    pub const BindKeyKind = enum {
        char,
        up,
        down,
        left,
        right,
        space,
    };

    pub const BindKey = union(BindKeyKind) {
        char: u8,
        up,
        down,
        left,
        right,
        space,
    };

    pub const BindActionTag = enum {
        mux_quit,
        mux_detach,
        pane_disown,
        pane_adopt,
        split_h,
        split_v,
        split_resize,
        tab_new,
        tab_next,
        tab_prev,
        tab_close,
        float_toggle,
        float_nudge,
        focus_move,
    };

    pub const BindAction = union(BindActionTag) {
        mux_quit,
        mux_detach,
        pane_disown,
        pane_adopt,
        split_h,
        split_v,
        split_resize: BindKeyKind, // up/down/left/right (resize divider)
        tab_new,
        tab_next,
        tab_prev,
        tab_close,
        float_toggle: u8, // float key (matches FloatDef.key)
        float_nudge: BindKeyKind, // up/down/left/right
        focus_move: BindKeyKind, // up/down/left/right
    };

    pub const BindContext = struct {
        focus: FocusContext = .any,
    };

    pub const Bind = struct {
        when: BindWhen = .press,
        mods: u8 = 0, // bitmask of KeyMod
        key: BindKey,
        context: BindContext = .{},
        action: BindAction,

        // Timing (used by hold/double_tap)
        hold_ms: ?i64 = null,
        double_tap_ms: ?i64 = null,
    };

    pub fn modsMaskFromStrings(mods: ?[]const []const u8) u8 {
        var mods_mask: u8 = 0;
        if (mods) |items| {
            for (items) |m| {
                if (std.mem.eql(u8, m, "alt")) mods_mask |= 1;
                if (std.mem.eql(u8, m, "ctrl")) mods_mask |= 2;
                if (std.mem.eql(u8, m, "shift")) mods_mask |= 4;
                if (std.mem.eql(u8, m, "super")) mods_mask |= 8;
            }
        }
        return mods_mask;
    }

    pub const InputConfig = struct {
        binds: []const Bind = &[_]Bind{},

        // Default timings
        hold_ms: i64 = 600,
        // If the same chord's primary key is pressed again within this window
        // (while modifiers remain logically held), treat it as repeat mode.
        repeat_ms: i64 = 100,
        double_tap_ms: i64 = 250,
    };

    // Config status for notifications
    status: lua_runtime.ConfigStatus = .loaded,
    status_message: ?[]const u8 = null,

    input: InputConfig = .{},

    // Confirmation popups
    confirm_on_exit: bool = false, // When Alt+q or last shell exits
    confirm_on_detach: bool = false,
    confirm_on_disown: bool = false, // When Alt+z disowns a pane
    confirm_on_close: bool = false, // When Alt+x closes a float/tab

    // Floating pane defaults
    float_width_percent: u8 = 60,
    float_height_percent: u8 = 60,
    float_padding_x: u8 = 1, // left/right padding inside border
    float_padding_y: u8 = 0, // top/bottom padding inside border
    // Float borders default to active=1, passive=237.
    float_color: BorderColor = .{},
    float_style_default: ?FloatStyle = null,

    // Named floats
    floats: []FloatDef = &[_]FloatDef{},

    // Splits
    splits: SplitsConfig = .{},

    // Tabs (includes status)
    tabs: TabsConfig = .{},

    // Notifications
    notifications: NotificationConfig = .{},

    // Internal
    _allocator: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) Config {
        var config = Config{};
        config._allocator = allocator;

        const path = lua_runtime.getConfigPath(allocator, "config.lua") catch return config;
        defer allocator.free(path);

        var runtime = LuaRuntime.init(allocator) catch {
            config.status = .@"error";
            config.status_message = allocator.dupe(u8, "failed to initialize Lua") catch null;
            return config;
        };
        defer runtime.deinit();

        runtime.loadConfig(path) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    config.status = .missing;
                },
                else => {
                    config.status = .@"error";
                    if (runtime.last_error) |msg| {
                        config.status_message = allocator.dupe(u8, msg) catch null;
                    }
                },
            }
            return config;
        };

        // Access the "mux" section of the config table
        if (runtime.pushTable(-1, "mux")) {
            parseConfig(&runtime, &config, allocator);
            runtime.pop();
        } else {
            config.status_message = allocator.dupe(u8, "no 'mux' section in config") catch null;
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            if (self.status_message) |msg| {
                alloc.free(msg);
            }
            if (self.input.binds.len > 0) {
                alloc.free(self.input.binds);
            }
            for (self.floats) |f| {
                if (f.command) |cmd| {
                    alloc.free(cmd);
                }
                if (f.title) |t| {
                    alloc.free(t);
                }
            }
            if (self.floats.len > 0) {
                alloc.free(self.floats);
            }
        }
    }

    pub fn getFloatByKey(self: *const Config, key: u8) ?*const FloatDef {
        for (self.floats) |*f| {
            if (f.key == key) return f;
        }
        return null;
    }
};

// ===== Lua config parsing =====

fn parseConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    // Parse input section
    if (runtime.pushTable(-1, "input")) {
        parseInputConfig(runtime, config, allocator);
        runtime.pop();
    }

    // Confirmation settings
    if (runtime.getBool(-1, "confirm_on_exit")) |v| config.confirm_on_exit = v;
    if (runtime.getBool(-1, "confirm_on_detach")) |v| config.confirm_on_detach = v;
    if (runtime.getBool(-1, "confirm_on_disown")) |v| config.confirm_on_disown = v;
    if (runtime.getBool(-1, "confirm_on_close")) |v| config.confirm_on_close = v;

    // Parse floats
    if (runtime.pushTable(-1, "floats")) {
        parseFloats(runtime, config, allocator);
        runtime.pop();
    }

    // Parse splits
    if (runtime.pushTable(-1, "splits")) {
        parseSplits(runtime, config);
        runtime.pop();
    }

    // Parse tabs
    if (runtime.pushTable(-1, "tabs")) {
        parseTabs(runtime, config, allocator);
        runtime.pop();
    }

    // Parse notifications
    if (runtime.pushTable(-1, "notifications")) {
        parseNotifications(runtime, config, allocator);
        runtime.pop();
    }
}

fn parseInputConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    // Parse timing
    if (runtime.pushTable(-1, "timing")) {
        if (runtime.getInt(i64, -1, "hold_ms")) |v| config.input.hold_ms = v;
        if (runtime.getInt(i64, -1, "repeat_ms")) |v| config.input.repeat_ms = v;
        if (runtime.getInt(i64, -1, "double_tap_ms")) |v| config.input.double_tap_ms = v;
        runtime.pop();
    }

    // Parse binds array
    if (runtime.pushTable(-1, "binds")) {
        config.input.binds = parseBinds(runtime, allocator);
        runtime.pop();
    }
}

fn parseBinds(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const Config.Bind {
    var list = std.ArrayList(Config.Bind).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseBind(runtime)) |bind| {
                list.append(allocator, bind) catch {};
            }
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]Config.Bind{};
}

fn parseBind(runtime: *LuaRuntime) ?Config.Bind {
    // Parse key (required)
    const key_str = runtime.getString(-1, "key") orelse return null;
    const key: Config.BindKey = blk: {
        if (key_str.len == 1) break :blk .{ .char = key_str[0] };
        if (std.mem.eql(u8, key_str, "space")) break :blk .space;
        if (std.mem.eql(u8, key_str, "up")) break :blk .up;
        if (std.mem.eql(u8, key_str, "down")) break :blk .down;
        if (std.mem.eql(u8, key_str, "left")) break :blk .left;
        if (std.mem.eql(u8, key_str, "right")) break :blk .right;
        return null;
    };

    // Parse action (required)
    const action: Config.BindAction = blk: {
        // Action can be a string or a table with type field
        if (runtime.typeOf(-1) == .table) {
            if (runtime.pushTable(-1, "action")) {
                defer runtime.pop();
                const action_type = runtime.getString(-1, "type") orelse return null;
                break :blk parseAction(runtime, action_type) orelse return null;
            }
        }
        // Try direct action string
        const action_str = runtime.getString(-1, "action") orelse return null;
        break :blk parseSimpleAction(action_str) orelse return null;
    };

    // Parse mods (array of modifier values to OR together, or single number)
    var mods: u8 = 0;
    if (runtime.pushTable(-1, "mods")) {
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toIntAt(u8, -1)) |m| {
                    mods |= m;
                }
                runtime.pop();
            }
        }
        runtime.pop();
    } else if (runtime.getInt(u8, -1, "mods")) |m| {
        mods = m;
    }

    // Parse when
    const when: Config.BindWhen = if (runtime.getString(-1, "when")) |w|
        std.meta.stringToEnum(Config.BindWhen, w) orelse .press
    else
        .press;

    // Parse context
    var context = Config.BindContext{};
    if (runtime.pushTable(-1, "context")) {
        if (runtime.getString(-1, "focus")) |f| {
            context.focus = std.meta.stringToEnum(Config.FocusContext, f) orelse .any;
        }
        runtime.pop();
    }

    return Config.Bind{
        .when = when,
        .mods = mods,
        .key = key,
        .context = context,
        .action = action,
        .hold_ms = runtime.getInt(i64, -1, "hold_ms"),
        .double_tap_ms = runtime.getInt(i64, -1, "double_tap_ms"),
    };
}

fn parseAction(runtime: *LuaRuntime, action_type: []const u8) ?Config.BindAction {
    if (std.mem.eql(u8, action_type, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action_type, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action_type, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action_type, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action_type, "split.h")) return .split_h;
    if (std.mem.eql(u8, action_type, "split.v")) return .split_v;
    if (std.mem.eql(u8, action_type, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action_type, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action_type, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action_type, "tab.close")) return .tab_close;

    if (std.mem.eql(u8, action_type, "split.resize")) {
        const dir = runtime.getString(-1, "dir") orelse return null;
        const d = std.meta.stringToEnum(Config.BindKeyKind, dir) orelse return null;
        if (d != .up and d != .down and d != .left and d != .right) return null;
        return .{ .split_resize = d };
    }
    if (std.mem.eql(u8, action_type, "float.toggle")) {
        const fk = runtime.getString(-1, "float") orelse return null;
        if (fk.len != 1) return null;
        return .{ .float_toggle = fk[0] };
    }
    if (std.mem.eql(u8, action_type, "float.nudge")) {
        const dir = runtime.getString(-1, "dir") orelse return null;
        const d = std.meta.stringToEnum(Config.BindKeyKind, dir) orelse return null;
        if (d != .up and d != .down and d != .left and d != .right) return null;
        return .{ .float_nudge = d };
    }
    if (std.mem.eql(u8, action_type, "focus.move")) {
        const dir = runtime.getString(-1, "dir") orelse return null;
        const d = std.meta.stringToEnum(Config.BindKeyKind, dir) orelse return null;
        if (d != .up and d != .down and d != .left and d != .right) return null;
        return .{ .focus_move = d };
    }

    return null;
}

fn parseSimpleAction(action: []const u8) ?Config.BindAction {
    if (std.mem.eql(u8, action, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action, "split.h")) return .split_h;
    if (std.mem.eql(u8, action, "split.v")) return .split_v;
    if (std.mem.eql(u8, action, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action, "tab.close")) return .tab_close;
    return null;
}

fn parseFloats(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    var float_list = std.ArrayList(FloatDef).empty;

    // Default values (from first keyless entry)
    var def_width: ?u8 = null;
    var def_height: ?u8 = null;
    var def_pos_x: ?u8 = null;
    var def_pos_y: ?u8 = null;
    var def_pad_x: ?u8 = null;
    var def_pad_y: ?u8 = null;
    var def_color: ?BorderColor = null;
    var def_style: ?FloatStyle = null;
    var def_attrs = FloatAttributes{};

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (!runtime.pushArrayElement(-1, i)) continue;
        defer runtime.pop();

        const key_str = runtime.getString(-1, "key") orelse "";

        // First entry without key = defaults
        if (i == 1 and key_str.len == 0) {
            parseFloatDefaults(runtime, &def_width, &def_height, &def_pos_x, &def_pos_y, &def_pad_x, &def_pad_y, &def_color, &def_style, &def_attrs, allocator);
            // Apply to config defaults
            if (def_width) |w| config.float_width_percent = w;
            if (def_height) |h| config.float_height_percent = h;
            if (def_pad_x) |p| config.float_padding_x = p;
            if (def_pad_y) |p| config.float_padding_y = p;
            if (def_color) |c| config.float_color = c;
            if (def_style) |s| config.float_style_default = s;
            continue;
        }

        if (key_str.len == 0) continue;
        const key = key_str[0];

        const command = runtime.getStringAlloc(-1, "command");
        const title = runtime.getStringAlloc(-1, "title");

        // Parse attributes
        var attrs = def_attrs;
        if (runtime.pushTable(-1, "attributes")) {
            if (runtime.getBool(-1, "exclusive")) |v| attrs.exclusive = v;
            if (runtime.getBool(-1, "per_cwd")) |v| attrs.per_cwd = v;
            if (runtime.getBool(-1, "sticky")) |v| attrs.sticky = v;
            if (runtime.getBool(-1, "global")) |v| attrs.global = v;
            if (runtime.getBool(-1, "destroy")) |v| attrs.destroy = v;
            if (runtime.getBool(-1, "isolated")) |v| attrs.isolated = v;
            runtime.pop();
        }

        // Parse per-float overrides
        var width: ?u8 = def_width;
        var height: ?u8 = def_height;
        var pos_x: ?u8 = def_pos_x;
        var pos_y: ?u8 = def_pos_y;
        var pad_x: ?u8 = def_pad_x;
        var pad_y: ?u8 = def_pad_y;
        var color: ?BorderColor = def_color;
        var style: ?FloatStyle = def_style;

        if (runtime.pushTable(-1, "size")) {
            if (runtime.getInt(u8, -1, "width")) |v| width = constrainPercent(v, 10, 100);
            if (runtime.getInt(u8, -1, "height")) |v| height = constrainPercent(v, 10, 100);
            runtime.pop();
        }
        if (runtime.getInt(u8, -1, "width")) |v| width = constrainPercent(v, 10, 100);
        if (runtime.getInt(u8, -1, "height")) |v| height = constrainPercent(v, 10, 100);

        if (runtime.pushTable(-1, "position")) {
            if (runtime.getInt(u8, -1, "x")) |v| pos_x = constrainPercent(v, 0, 100);
            if (runtime.getInt(u8, -1, "y")) |v| pos_y = constrainPercent(v, 0, 100);
            runtime.pop();
        }
        if (runtime.getInt(u8, -1, "pos_x")) |v| pos_x = constrainPercent(v, 0, 100);
        if (runtime.getInt(u8, -1, "pos_y")) |v| pos_y = constrainPercent(v, 0, 100);

        if (runtime.pushTable(-1, "padding")) {
            if (runtime.getInt(u8, -1, "x")) |v| pad_x = constrainPercent(v, 0, 10);
            if (runtime.getInt(u8, -1, "y")) |v| pad_y = constrainPercent(v, 0, 10);
            runtime.pop();
        }
        if (runtime.getInt(u8, -1, "padding_x")) |v| pad_x = constrainPercent(v, 0, 10);
        if (runtime.getInt(u8, -1, "padding_y")) |v| pad_y = constrainPercent(v, 0, 10);

        if (runtime.pushTable(-1, "color")) {
            var c = color orelse BorderColor{};
            if (runtime.getInt(u8, -1, "active")) |v| c.active = v;
            if (runtime.getInt(u8, -1, "passive")) |v| c.passive = v;
            color = c;
            runtime.pop();
        }

        if (runtime.pushTable(-1, "style")) {
            style = parseFloatStyle(runtime, allocator);
            runtime.pop();
        }

        float_list.append(allocator, .{
            .key = key,
            .command = command,
            .title = title,
            .attributes = attrs,
            .width_percent = width,
            .height_percent = height,
            .pos_x = pos_x,
            .pos_y = pos_y,
            .padding_x = pad_x,
            .padding_y = pad_y,
            .color = color,
            .style = style,
        }) catch continue;
    }

    config.floats = float_list.toOwnedSlice(allocator) catch &[_]FloatDef{};
}

fn parseFloatDefaults(
    runtime: *LuaRuntime,
    width: *?u8,
    height: *?u8,
    pos_x: *?u8,
    pos_y: *?u8,
    pad_x: *?u8,
    pad_y: *?u8,
    color: *?BorderColor,
    style: *?FloatStyle,
    attrs: *FloatAttributes,
    allocator: std.mem.Allocator,
) void {
    if (runtime.pushTable(-1, "size")) {
        if (runtime.getInt(u8, -1, "width")) |v| width.* = constrainPercent(v, 10, 100);
        if (runtime.getInt(u8, -1, "height")) |v| height.* = constrainPercent(v, 10, 100);
        runtime.pop();
    }
    if (runtime.getInt(u8, -1, "width")) |v| width.* = constrainPercent(v, 10, 100);
    if (runtime.getInt(u8, -1, "height")) |v| height.* = constrainPercent(v, 10, 100);

    if (runtime.pushTable(-1, "position")) {
        if (runtime.getInt(u8, -1, "x")) |v| pos_x.* = constrainPercent(v, 0, 100);
        if (runtime.getInt(u8, -1, "y")) |v| pos_y.* = constrainPercent(v, 0, 100);
        runtime.pop();
    }
    if (runtime.getInt(u8, -1, "pos_x")) |v| pos_x.* = constrainPercent(v, 0, 100);
    if (runtime.getInt(u8, -1, "pos_y")) |v| pos_y.* = constrainPercent(v, 0, 100);

    if (runtime.pushTable(-1, "padding")) {
        if (runtime.getInt(u8, -1, "x")) |v| pad_x.* = constrainPercent(v, 0, 10);
        if (runtime.getInt(u8, -1, "y")) |v| pad_y.* = constrainPercent(v, 0, 10);
        runtime.pop();
    }
    if (runtime.getInt(u8, -1, "padding_x")) |v| pad_x.* = constrainPercent(v, 0, 10);
    if (runtime.getInt(u8, -1, "padding_y")) |v| pad_y.* = constrainPercent(v, 0, 10);

    if (runtime.pushTable(-1, "color")) {
        var c = BorderColor{};
        if (runtime.getInt(u8, -1, "active")) |v| c.active = v;
        if (runtime.getInt(u8, -1, "passive")) |v| c.passive = v;
        color.* = c;
        runtime.pop();
    }

    if (runtime.pushTable(-1, "style")) {
        style.* = parseFloatStyle(runtime, allocator);
        runtime.pop();
    }

    if (runtime.pushTable(-1, "attributes")) {
        if (runtime.getBool(-1, "exclusive")) |v| attrs.exclusive = v;
        if (runtime.getBool(-1, "per_cwd")) |v| attrs.per_cwd = v;
        if (runtime.getBool(-1, "sticky")) |v| attrs.sticky = v;
        if (runtime.getBool(-1, "global")) |v| attrs.global = v;
        if (runtime.getBool(-1, "destroy")) |v| attrs.destroy = v;
        if (runtime.getBool(-1, "isolated")) |v| attrs.isolated = v;
        runtime.pop();
    }
}

fn parseFloatStyle(runtime: *LuaRuntime, allocator: std.mem.Allocator) FloatStyle {
    var result = FloatStyle{};

    // Border characters
    if (runtime.pushTable(-1, "border")) {
        if (runtime.pushTable(-1, "chars")) {
            result.top_left = lua_runtime.parseUnicodeChar(runtime, -1, "top_left", 0x256D);
            result.top_right = lua_runtime.parseUnicodeChar(runtime, -1, "top_right", 0x256E);
            result.bottom_left = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_left", 0x2570);
            result.bottom_right = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_right", 0x256F);
            result.horizontal = lua_runtime.parseUnicodeChar(runtime, -1, "horizontal", 0x2500);
            result.vertical = lua_runtime.parseUnicodeChar(runtime, -1, "vertical", 0x2502);
            result.cross = lua_runtime.parseUnicodeChar(runtime, -1, "cross", 0x253C);
            result.top_t = lua_runtime.parseUnicodeChar(runtime, -1, "top_t", 0x252C);
            result.bottom_t = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_t", 0x2534);
            result.left_t = lua_runtime.parseUnicodeChar(runtime, -1, "left_t", 0x251C);
            result.right_t = lua_runtime.parseUnicodeChar(runtime, -1, "right_t", 0x2524);
            runtime.pop();
        }
        runtime.pop();
    }

    // Legacy flat border chars
    result.top_left = lua_runtime.parseUnicodeChar(runtime, -1, "top_left", result.top_left);
    result.top_right = lua_runtime.parseUnicodeChar(runtime, -1, "top_right", result.top_right);
    result.bottom_left = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_left", result.bottom_left);
    result.bottom_right = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_right", result.bottom_right);
    result.horizontal = lua_runtime.parseUnicodeChar(runtime, -1, "horizontal", result.horizontal);
    result.vertical = lua_runtime.parseUnicodeChar(runtime, -1, "vertical", result.vertical);

    // Shadow
    if (runtime.pushTable(-1, "shadow")) {
        if (runtime.getInt(u8, -1, "color")) |c| result.shadow_color = c;
        runtime.pop();
    }

    // Title
    if (runtime.pushTable(-1, "title")) {
        if (runtime.getString(-1, "position")) |pos_str| {
            result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
        }
        result.module = parseStatusModule(runtime, allocator);
        runtime.pop();
    }

    // Legacy flat position
    if (runtime.getString(-1, "position")) |pos_str| {
        result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
    }

    return result;
}

fn parseSplits(runtime: *LuaRuntime, config: *Config) void {
    if (runtime.pushTable(-1, "color")) {
        if (runtime.getInt(u8, -1, "active")) |v| config.splits.color.active = v;
        if (runtime.getInt(u8, -1, "passive")) |v| config.splits.color.passive = v;
        runtime.pop();
    }

    config.splits.separator_v = lua_runtime.parseUnicodeChar(runtime, -1, "separator_v", config.splits.separator_v);
    config.splits.separator_h = lua_runtime.parseUnicodeChar(runtime, -1, "separator_h", config.splits.separator_h);

    if (runtime.pushTable(-1, "style")) {
        var style = SplitStyle{};
        style.vertical = lua_runtime.parseUnicodeChar(runtime, -1, "vertical", 0x2502);
        style.horizontal = lua_runtime.parseUnicodeChar(runtime, -1, "horizontal", 0x2500);
        style.cross = lua_runtime.parseUnicodeChar(runtime, -1, "cross", 0x253C);
        style.top_t = lua_runtime.parseUnicodeChar(runtime, -1, "top_t", 0x252C);
        style.bottom_t = lua_runtime.parseUnicodeChar(runtime, -1, "bottom_t", 0x2534);
        style.left_t = lua_runtime.parseUnicodeChar(runtime, -1, "left_t", 0x251C);
        style.right_t = lua_runtime.parseUnicodeChar(runtime, -1, "right_t", 0x2524);
        config.splits.style = style;
        runtime.pop();
    }
}

fn parseTabs(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    if (runtime.pushTable(-1, "status")) {
        if (runtime.getBool(-1, "enabled")) |v| config.tabs.status.enabled = v;

        if (runtime.pushTable(-1, "left")) {
            config.tabs.status.left = parseStatusModules(runtime, allocator);
            runtime.pop();
        }
        if (runtime.pushTable(-1, "center")) {
            config.tabs.status.center = parseStatusModules(runtime, allocator);
            runtime.pop();
        }
        if (runtime.pushTable(-1, "right")) {
            config.tabs.status.right = parseStatusModules(runtime, allocator);
            runtime.pop();
        }
        runtime.pop();
    }
}

fn parseStatusModules(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const StatusModule {
    var list = std.ArrayList(StatusModule).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseStatusModule(runtime, allocator)) |mod| {
                list.append(allocator, mod) catch {};
            }
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]StatusModule{};
}

fn parseStatusModule(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?StatusModule {
    const name = runtime.getStringAlloc(-1, "name") orelse return null;

    return StatusModule{
        .name = name,
        .priority = lua_runtime.parseConstrainedInt(runtime, u8, -1, "priority", 1, 255, 50),
        .outputs = parseOutputs(runtime, allocator),
        .command = runtime.getStringAlloc(-1, "command"),
        .when = runtime.getStringAlloc(-1, "when"),
        .active_style = runtime.getStringAlloc(-1, "active_style") orelse "bg:1 fg:0",
        .inactive_style = runtime.getStringAlloc(-1, "inactive_style") orelse "bg:237 fg:250",
        .separator = runtime.getStringAlloc(-1, "separator") orelse " | ",
        .separator_style = runtime.getStringAlloc(-1, "separator_style") orelse "fg:7",
        .tab_title = runtime.getStringAlloc(-1, "tab_title") orelse "basename",
        .left_arrow = runtime.getStringAlloc(-1, "left_arrow") orelse "",
        .right_arrow = runtime.getStringAlloc(-1, "right_arrow") orelse "",
    };
}

fn parseOutputs(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const OutputDef {
    if (!runtime.pushTable(-1, "outputs")) {
        return &[_]OutputDef{};
    }
    defer runtime.pop();

    var list = std.ArrayList(OutputDef).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            list.append(allocator, .{
                .style = runtime.getStringAlloc(-1, "style") orelse "",
                .format = runtime.getStringAlloc(-1, "format") orelse "$output",
            }) catch {};
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]OutputDef{};
}

fn parseNotifications(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    if (runtime.pushTable(-1, "mux")) {
        parseNotificationStyle(runtime, &config.notifications.mux, allocator);
        runtime.pop();
    }
    if (runtime.pushTable(-1, "pane")) {
        parseNotificationStyle(runtime, &config.notifications.pane, allocator);
        runtime.pop();
    }
}

fn parseNotificationStyle(runtime: *LuaRuntime, style: *NotificationStyleConfig, allocator: std.mem.Allocator) void {
    style.fg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "fg", 0, 255, style.fg);
    style.bg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "bg", 0, 255, style.bg);
    if (runtime.getBool(-1, "bold")) |v| style.bold = v;
    style.padding_x = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_x", 0, 10, style.padding_x);
    style.padding_y = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_y", 0, 10, style.padding_y);
    style.offset = lua_runtime.parseConstrainedInt(runtime, u8, -1, "offset", 0, 20, style.offset);
    style.duration_ms = lua_runtime.parseConstrainedInt(runtime, u32, -1, "duration_ms", 100, 60000, style.duration_ms);
    if (runtime.getStringAlloc(-1, "alignment")) |v| style.alignment = v else _ = allocator;
}

fn constrainPercent(val: u8, min: u8, max: u8) u8 {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}
