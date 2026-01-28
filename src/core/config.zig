const std = @import("std");
const posix = std.posix;
const lua_runtime = @import("lua_runtime.zig");
const LuaRuntime = lua_runtime.LuaRuntime;

const log = std.log.scoped(.config);

threadlocal var PARSE_ERROR: ?[]const u8 = null;

fn setParseError(allocator: std.mem.Allocator, msg: []const u8) void {
    if (PARSE_ERROR != null) return;
    PARSE_ERROR = allocator.dupe(u8, msg) catch null;
}

/// Output definition for status modules (style + format pair)
pub const OutputDef = struct {
    style: []const u8 = "",
    format: []const u8 = "$output",
};

/// Spinner definition for mux statusbar modules.
pub const SpinnerDef = struct {
    kind: []const u8 = "knight_rider",
    width: u8 = 8,
    step_ms: u64 = 75,
    hold_frames: u8 = 9,
    trail_len: u8 = 6,
    colors: []const u8 = &[_]u8{},
    bg_color: ?u8 = null,
    placeholder_color: ?u8 = null,

    // Filled at render time by the statusbar module.
    started_at_ms: u64 = 0,

    pub fn deinit(self: *SpinnerDef, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        if (self.colors.len > 0) allocator.free(self.colors);
        if (self.placeholder_color) |_| {}
        self.* = .{};
    }
};

/// Unified condition for keybindings, segments, and prompts.
///
/// Syntax:
///   when = "token"                              -- single token
///   when = { all = { "a", "b" } }               -- AND
///   when = { any = { "a", "b" } }               -- OR
///   when = { any = { { all = { "a", "b" } }, "c" } }  -- OR of ANDs
///   when = { bash = "..." }                     -- bash script
///   when = { lua = "..." }                      -- lua script
pub const WhenDef = struct {
    /// AND of tokens (flat list, no namespaces needed)
    all: ?[][]const u8 = null,
    /// OR of conditions
    any: ?[]const WhenDef = null,
    /// Bash script condition
    bash: ?[]const u8 = null,
    /// Lua script condition
    lua: ?[]const u8 = null,
    /// Fast env var check (true if set and non-empty)
    env: ?[]const u8 = null,
    /// Fast env var check (true if NOT set or empty)
    env_not: ?[]const u8 = null,

    pub fn deinit(self: *WhenDef, allocator: std.mem.Allocator) void {
        if (self.all) |items| {
            for (items) |s| allocator.free(@constCast(s));
            allocator.free(items);
        }
        if (self.any) |items| {
            for (items) |*w| {
                var mw = @constCast(w);
                mw.deinit(allocator);
            }
            allocator.free(items);
        }
        if (self.bash) |s| allocator.free(@constCast(s));
        if (self.lua) |s| allocator.free(@constCast(s));
        if (self.env) |s| allocator.free(@constCast(s));
        if (self.env_not) |s| allocator.free(@constCast(s));
        self.* = .{};
    }
};

/// Segment definition for statusbar and prompt.
/// Both statusbar modules and shell prompt segments use this unified type.
pub const Segment = struct {
    name: []const u8,
    // Priority for width-based hiding (lower = higher priority, stays longer)
    priority: u8 = 50,
    // Array of outputs (each with style + format)
    outputs: []const OutputDef = &[_]OutputDef{},
    // Optional for custom modules
    command: ?[]const u8 = null,
    when: ?WhenDef = null,

    // Optional spinner configuration
    spinner: ?SpinnerDef = null,
    // For tabs segment
    active_style: []const u8 = "bg:1 fg:0",
    inactive_style: []const u8 = "bg:237 fg:250",
    separator: []const u8 = " | ",
    separator_style: []const u8 = "fg:7",
    // For tabs segment: what to show as tab title ("name" or "basename")
    tab_title: []const u8 = "basename",
    // For tabs segment: arrow decorations (empty string = no arrows)
    left_arrow: []const u8 = "",
    right_arrow: []const u8 = "",
};

/// Status bar config
pub const StatusBarConfig = struct {
    enabled: bool = true,
    left: []const Segment = &[_]Segment{},
    center: []const Segment = &[_]Segment{},
    right: []const Segment = &[_]Segment{},
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
    module: ?Segment = null,
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
    status: StatusBarConfig = .{},
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

// ===== Layout definitions for ses section =====

/// Single pane in a layout
pub const LayoutPaneDef = struct {
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,

    pub fn deinit(self: *LayoutPaneDef, allocator: std.mem.Allocator) void {
        if (self.cwd) |c| allocator.free(@constCast(c));
        if (self.command) |c| allocator.free(@constCast(c));
    }
};

/// Split or pane (recursive definition)
pub const LayoutSplitDef = union(enum) {
    pane: LayoutPaneDef,
    split: struct {
        dir: []const u8, // "h" or "v"
        ratio: f32 = 0.5,
        first: *LayoutSplitDef,
        second: *LayoutSplitDef,
    },

    pub fn deinit(self: *LayoutSplitDef, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pane => |*p| {
                var pane = @constCast(p);
                pane.deinit(allocator);
            },
            .split => |*s| {
                allocator.free(@constCast(s.dir));
                s.first.deinit(allocator);
                allocator.destroy(s.first);
                s.second.deinit(allocator);
                allocator.destroy(s.second);
            },
        }
    }
};

/// Tab in a layout
pub const LayoutTabDef = struct {
    name: []const u8,
    enabled: bool = true,
    root: ?LayoutSplitDef = null,

    pub fn deinit(self: *LayoutTabDef, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.name));
        if (self.root) |*r| {
            var root = @constCast(r);
            root.deinit(allocator);
        }
    }
};

/// Float in a layout (includes all FloatDef fields + enabled)
pub const LayoutFloatDef = struct {
    enabled: bool = true,
    key: u8,
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
    attributes: FloatAttributes = .{},
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    pos_x: ?u8 = null,
    pos_y: ?u8 = null,
    padding_x: ?u8 = null,
    padding_y: ?u8 = null,
    color: ?BorderColor = null,
    style: ?FloatStyle = null,

    pub fn deinit(self: *LayoutFloatDef, allocator: std.mem.Allocator) void {
        if (self.command) |c| allocator.free(@constCast(c));
        if (self.title) |t| allocator.free(@constCast(t));
        // TODO: style.module cleanup if needed
    }
};

/// Full layout definition
pub const LayoutDef = struct {
    name: []const u8,
    enabled: bool = false,
    tabs: []LayoutTabDef = &[_]LayoutTabDef{},
    floats: []LayoutFloatDef = &[_]LayoutFloatDef{},

    pub fn deinit(self: *LayoutDef, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.name));
        for (self.tabs) |*tab| {
            var t = @constCast(tab);
            t.deinit(allocator);
        }
        if (self.tabs.len > 0) {
            allocator.free(self.tabs);
        }
        for (self.floats) |*float| {
            var f = @constCast(float);
            f.deinit(allocator);
        }
        if (self.floats.len > 0) {
            allocator.free(self.floats);
        }
    }
};

/// Ses configuration
pub const SesConfig = struct {
    layouts: []LayoutDef = &[_]LayoutDef{},

    pub fn deinit(self: *SesConfig, allocator: std.mem.Allocator) void {
        for (self.layouts) |*layout| {
            var l = @constCast(layout);
            l.deinit(allocator);
        }
        if (self.layouts.len > 0) {
            allocator.free(self.layouts);
        }
    }

    pub fn load(allocator: std.mem.Allocator) SesConfig {
        var config = SesConfig{};

        var runtime = LuaRuntime.init(allocator) catch return config;
        defer runtime.deinit();

        // Set section to "ses"
        runtime.setHexeSection("ses");

        // Load global config
        const config_path = lua_runtime.getConfigPath(allocator, "config.lua") catch return config;
        defer allocator.free(config_path);

        runtime.loadConfig(config_path) catch return config;

        // Access the "ses" section of global config
        if (runtime.pushTable(-1, "ses")) {
            parseSesConfig(&runtime, &config, allocator);
            runtime.pop();
        }

        // Pop global config table
        runtime.pop();

        // Try to load local .hexe.lua from current directory
        const local_path = allocator.dupe(u8, ".hexe.lua") catch return config;
        defer allocator.free(local_path);

        // Check if local config exists
        std.fs.cwd().access(local_path, .{}) catch {
            // No local config, use global only
            return config;
        };

        // Local config exists, load it and merge/overwrite
        runtime.loadConfig(local_path) catch {
            // Failed to load local config, but global is already loaded
            return config;
        };

        // Access the "ses" section of local config and merge
        if (runtime.pushTable(-1, "ses")) {
            parseSesConfig(&runtime, &config, allocator);
            runtime.pop();
        }

        // Pop local config table
        runtime.pop();

        return config;
    }
};

pub const Config = struct {
    pub const KeyMod = enum {
        alt,
        ctrl,
        shift,
        super,
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
        pane_select_mode,
        keycast_toggle,
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
        pane_select_mode, // enter pane select mode (focus or swap)
        keycast_toggle, // toggle keycast overlay
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

    pub const Bind = struct {
        on: BindWhen = .press,
        mods: u8 = 0, // bitmask of KeyMod
        key: BindKey,
        action: BindAction,
        /// Condition for when this bind is active.
        when: ?WhenDef = null,

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

    pub const MouseConfig = struct {
        /// Modifier chord required to override the default mouse routing.
        ///
        /// When this chord is held during mouse drag, the mux will perform
        /// pane-local selection even when the target pane is in alt-screen.
        ///
        /// Bitmask uses hx.mod values (alt=1, ctrl=2, shift=4, super=8).
        selection_override_mods: u8 = 1 | 2, // default: Ctrl+Alt
    };

    // Config status for notifications
    status: lua_runtime.ConfigStatus = .loaded,
    status_message: ?[]const u8 = null,

    input: InputConfig = .{},

    mouse: MouseConfig = .{},

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

    // Selection color (palette index, default 240)
    selection_color: u8 = 240,

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

        PARSE_ERROR = null;

        const path = lua_runtime.getConfigPath(allocator, "config.lua") catch return config;
        defer allocator.free(path);

        var runtime = LuaRuntime.init(allocator) catch {
            config.status = .@"error";
            config.status_message = allocator.dupe(u8, "failed to initialize Lua") catch null;
            return config;
        };
        defer runtime.deinit();

        // Let a single config.lua avoid building other sections.
        runtime.setHexeSection("mux");

        // Load global config
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

        // Access the "mux" section of the global config table
        if (runtime.pushTable(-1, "mux")) {
            log.debug("parsing mux section from global config", .{});
            parseConfig(&runtime, &config, allocator);
            runtime.pop();
        } else {
            config.status_message = allocator.dupe(u8, "no 'mux' section in config") catch null;
        }

        // Pop global config table
        runtime.pop();

        // Try to load local .hexe.lua from current directory
        const local_path = allocator.dupe(u8, ".hexe.lua") catch return config;
        defer allocator.free(local_path);

        log.debug("checking for local config: {s}", .{local_path});

        // Check if local config exists
        std.fs.cwd().access(local_path, .{}) catch {
            // No local config, use global only
            log.debug("no local config found", .{});
            if (config.status != .@"error") {
                if (PARSE_ERROR) |msg| {
                    config.status = .@"error";
                    config.status_message = msg;
                    PARSE_ERROR = null;
                }
            }
            return config;
        };

        log.info("loading local config from: {s}", .{local_path});

        // Local config exists, load it and merge/overwrite
        runtime.loadConfig(local_path) catch |err| {
            // Failed to load local config, but global is already loaded
            log.warn("failed to load local config: {}", .{err});
            if (config.status != .@"error") {
                if (PARSE_ERROR) |msg| {
                    config.status = .@"error";
                    config.status_message = msg;
                    PARSE_ERROR = null;
                }
            }
            return config;
        };

        // Access the "mux" section of the local config table and merge
        if (runtime.pushTable(-1, "mux")) {
            log.info("parsing mux section from local config", .{});
            parseConfig(&runtime, &config, allocator);
            runtime.pop();
        } else {
            log.warn("no mux section in local config", .{});
        }

        // Pop local config table
        runtime.pop();

        if (config.status != .@"error") {
            if (PARSE_ERROR) |msg| {
                config.status = .@"error";
                config.status_message = msg;
                PARSE_ERROR = null;
            }
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
            if (self.status_message) |msg| {
                alloc.free(msg);
            }
            if (self.input.binds.len > 0) {
                for (self.input.binds) |b| {
                    if (b.when) |w| {
                        var mw = w;
                        mw.deinit(alloc);
                    }
                }
                alloc.free(self.input.binds);
            }
        }
    }
};

// ===== Lua config parsing =====

fn parseConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    // Parse input section
    if (runtime.pushTable(-1, "input")) {
        parseInputConfig(runtime, config, allocator);
        runtime.pop();
    }

    // Parse mouse section
    if (runtime.pushTable(-1, "mouse")) {
        parseMouseConfig(runtime, config);
        runtime.pop();
    }

    // Confirmation settings
    if (runtime.getBool(-1, "confirm_on_exit")) |v| config.confirm_on_exit = v;
    if (runtime.getBool(-1, "confirm_on_detach")) |v| config.confirm_on_detach = v;
    if (runtime.getBool(-1, "confirm_on_disown")) |v| config.confirm_on_disown = v;
    if (runtime.getBool(-1, "confirm_on_close")) |v| config.confirm_on_close = v;

    // Selection color
    if (runtime.getInt(u8, -1, "selection_color")) |v| config.selection_color = v;

    // Parse float defaults
    if (runtime.pushTable(-1, "float")) {
        parseFloat(runtime, config, allocator);
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

fn parseMouseConfig(runtime: *LuaRuntime, config: *Config) void {
    // Accept either:
    // - selection_override_mods = <number>
    // - selection_override_mods = { hx.mod.ctrl, hx.mod.alt }
    if (runtime.pushTable(-1, "selection_override_mods")) {
        defer runtime.pop();
        var mask: u8 = 0;
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toIntAt(u8, -1)) |m| {
                    mask |= m;
                }
                runtime.pop();
            }
        }
        config.mouse.selection_override_mods = mask;
        return;
    }

    if (runtime.getInt(u8, -1, "selection_override_mods")) |m| {
        config.mouse.selection_override_mods = m;
    }
}

fn parseInputConfig(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    log.debug("parsing input config", .{});

    // Parse timing
    if (runtime.pushTable(-1, "timing")) {
        if (runtime.getInt(i64, -1, "hold_ms")) |v| config.input.hold_ms = v;
        if (runtime.getInt(i64, -1, "repeat_ms")) |v| config.input.repeat_ms = v;
        if (runtime.getInt(i64, -1, "double_tap_ms")) |v| config.input.double_tap_ms = v;
        runtime.pop();
    }

    // Parse binds array
    if (runtime.pushTable(-1, "binds")) {
        const old_count = config.input.binds.len;
        config.input.binds = parseBinds(runtime, allocator, config.input.binds);
        log.info("parsed {} keybindings (was {})", .{config.input.binds.len, old_count});
        runtime.pop();
    }
}

fn parseBinds(runtime: *LuaRuntime, allocator: std.mem.Allocator, existing: []const Config.Bind) []const Config.Bind {
    var list = std.ArrayList(Config.Bind).empty;

    // Add existing binds first
    log.debug("parseBinds: starting with {} existing binds", .{existing.len});
    for (existing) |bind| {
        list.append(allocator, bind) catch {};
    }

    const len = runtime.getArrayLen(-1);
    log.debug("parseBinds: found {} new binds to parse", .{len});

    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseBind(runtime, allocator)) |bind| {
                log.debug("parseBinds: successfully parsed bind #{}", .{i});
                list.append(allocator, bind) catch {};
            } else {
                log.warn("parseBinds: failed to parse bind #{}", .{i});
            }
            runtime.pop();
        }
    }

    const final_count = list.items.len;
    log.debug("parseBinds: returning {} total binds", .{final_count});
    return list.toOwnedSlice(allocator) catch &[_]Config.Bind{};
}

fn parseBind(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?Config.Bind {
    // Parse key (required)
    const key_str = runtime.getString(-1, "key") orelse {
        log.warn("parseBind: no 'key' field found", .{});
        return null;
    };
    log.debug("parseBind: parsing bind with key='{s}'", .{key_str});

    const key: Config.BindKey = blk: {
        if (key_str.len == 1) break :blk .{ .char = key_str[0] };
        if (std.mem.eql(u8, key_str, "space")) break :blk .space;
        if (std.mem.eql(u8, key_str, "up")) break :blk .up;
        if (std.mem.eql(u8, key_str, "down")) break :blk .down;
        if (std.mem.eql(u8, key_str, "left")) break :blk .left;
        if (std.mem.eql(u8, key_str, "right")) break :blk .right;
        log.warn("parseBind: invalid key '{s}'", .{key_str});
        return null;
    };

    // Parse action (required)
    const action: Config.BindAction = blk: {
        // Action can be a string or a table with type field
        if (runtime.typeOf(-1) == .table) {
            if (runtime.pushTable(-1, "action")) {
                defer runtime.pop();
                const action_type = runtime.getString(-1, "type") orelse {
                    log.warn("parseBind: action table has no 'type' field", .{});
                    return null;
                };
                log.debug("parseBind: parsing action type '{s}'", .{action_type});
                break :blk parseAction(runtime, action_type) orelse {
                    log.warn("parseBind: failed to parse action type '{s}'", .{action_type});
                    return null;
                };
            }
        }
        // Try direct action string
        log.debug("parseBind: trying to parse action as string", .{});
        const action_str = runtime.getString(-1, "action") orelse {
            log.warn("parseBind: no 'action' field found (neither table nor string)", .{});
            return null;
        };
        break :blk parseSimpleAction(action_str) orelse {
            log.warn("parseBind: failed to parse simple action '{s}'", .{action_str});
            return null;
        };
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

    // Parse on (press/release/repeat/hold/double_tap)
    const on: Config.BindWhen = if (runtime.getString(-1, "on")) |o|
        std.meta.stringToEnum(Config.BindWhen, o) orelse .press
    else
        .press;

    // Parse when (condition)
    const when = parseWhenTable(runtime, allocator, true);

    return Config.Bind{
        .on = on,
        .mods = mods,
        .key = key,
        .action = action,
        .when = when,
        .hold_ms = runtime.getInt(i64, -1, "hold_ms"),
        .double_tap_ms = runtime.getInt(i64, -1, "double_tap_ms"),
    };
}

fn parseStringList(runtime: *LuaRuntime, allocator: std.mem.Allocator, key: [:0]const u8) ?[][]u8 {
    // Accept either: key = {"a","b"} or key = "a"
    if (runtime.pushTable(-1, key)) {
        defer runtime.pop();
        var out = std.ArrayList([]u8).empty;
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toStringAt(-1)) |s| {
                    const dup = allocator.dupe(u8, s) catch null;
                    if (dup) |d| {
                        out.append(allocator, d) catch allocator.free(d);
                    }
                }
                runtime.pop();
            }
        }
        return out.toOwnedSlice(allocator) catch null;
    }

    if (runtime.getString(-1, key)) |s| {
        const one = allocator.dupe(u8, s) catch return null;
        const slice = allocator.alloc([]u8, 1) catch {
            allocator.free(one);
            return null;
        };
        slice[0] = one;
        return slice;
    }

    return null;
}

fn parseAction(runtime: *LuaRuntime, action_type: []const u8) ?Config.BindAction {
    if (std.mem.eql(u8, action_type, "mux.quit")) return .mux_quit;
    if (std.mem.eql(u8, action_type, "mux.detach")) return .mux_detach;
    if (std.mem.eql(u8, action_type, "pane.disown")) return .pane_disown;
    if (std.mem.eql(u8, action_type, "pane.adopt")) return .pane_adopt;
    if (std.mem.eql(u8, action_type, "pane.select_mode")) return .pane_select_mode;
    if (std.mem.eql(u8, action_type, "overlay.keycast_toggle")) return .keycast_toggle;
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
    if (std.mem.eql(u8, action, "pane.select_mode")) return .pane_select_mode;
    if (std.mem.eql(u8, action, "overlay.keycast_toggle")) return .keycast_toggle;
    if (std.mem.eql(u8, action, "split.h")) return .split_h;
    if (std.mem.eql(u8, action, "split.v")) return .split_v;
    if (std.mem.eql(u8, action, "tab.new")) return .tab_new;
    if (std.mem.eql(u8, action, "tab.next")) return .tab_next;
    if (std.mem.eql(u8, action, "tab.prev")) return .tab_prev;
    if (std.mem.eql(u8, action, "tab.close")) return .tab_close;
    return null;
}

fn parseFloat(runtime: *LuaRuntime, config: *Config, allocator: std.mem.Allocator) void {
    // Parse default float settings from float = {} table
    var width: ?u8 = null;
    var height: ?u8 = null;
    var pad_x: ?u8 = null;
    var pad_y: ?u8 = null;
    var color: ?BorderColor = null;
    var style: ?FloatStyle = null;

    if (runtime.pushTable(-1, "size")) {
        if (runtime.getInt(u8, -1, "width")) |v| width = constrainPercent(v, 10, 100);
        if (runtime.getInt(u8, -1, "height")) |v| height = constrainPercent(v, 10, 100);
        runtime.pop();
    }

    if (runtime.pushTable(-1, "padding")) {
        if (runtime.getInt(u8, -1, "x")) |v| pad_x = constrainPercent(v, 0, 10);
        if (runtime.getInt(u8, -1, "y")) |v| pad_y = constrainPercent(v, 0, 10);
        runtime.pop();
    }

    if (runtime.pushTable(-1, "color")) {
        var c = BorderColor{};
        if (runtime.getInt(u8, -1, "active")) |v| c.active = v;
        if (runtime.getInt(u8, -1, "passive")) |v| c.passive = v;
        color = c;
        runtime.pop();
    }

    if (runtime.pushTable(-1, "style")) {
        style = parseFloatStyle(runtime, allocator);
        runtime.pop();
    }

    // Apply to config defaults
    if (width) |w| config.float_width_percent = w;
    if (height) |h| config.float_height_percent = h;
    if (pad_x) |p| config.float_padding_x = p;
    if (pad_y) |p| config.float_padding_y = p;
    if (color) |c| config.float_color = c;
    if (style) |s| config.float_style_default = s;
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
        // For float titles we allow omitting `name` and default to "title".
        // The module outputs define styling for the title text.
        result.module = parseSegmentWithDefaultName(runtime, allocator, "title");
        runtime.pop();
    }

    // Legacy flat position
    if (runtime.getString(-1, "position")) |pos_str| {
        result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
    }

    return result;
}

fn parseSegmentWithDefaultName(runtime: *LuaRuntime, allocator: std.mem.Allocator, default_name: ?[]const u8) ?Segment {
    const name = runtime.getStringAlloc(-1, "name") orelse blk: {
        if (default_name) |dn| {
            break :blk allocator.dupe(u8, dn) catch return null;
        }
        return null;
    };

    return Segment{
        .name = name,
        .priority = lua_runtime.parseConstrainedInt(runtime, u8, -1, "priority", 1, 255, 50),
        .outputs = parseOutputs(runtime, allocator),
        .command = runtime.getStringAlloc(-1, "command"),
        .when = parseWhenTable(runtime, allocator, true),
        .spinner = parseSpinner(runtime, allocator),
        .active_style = runtime.getStringAlloc(-1, "active_style") orelse "bg:1 fg:0",
        .inactive_style = runtime.getStringAlloc(-1, "inactive_style") orelse "bg:237 fg:250",
        .separator = runtime.getStringAlloc(-1, "separator") orelse " | ",
        .separator_style = runtime.getStringAlloc(-1, "separator_style") orelse "fg:7",
        .tab_title = runtime.getStringAlloc(-1, "tab_title") orelse "basename",
        .left_arrow = runtime.getStringAlloc(-1, "left_arrow") orelse "",
        .right_arrow = runtime.getStringAlloc(-1, "right_arrow") orelse "",
    };
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
            config.tabs.status.left = parseSegments(runtime, allocator);
            runtime.pop();
        }
        if (runtime.pushTable(-1, "center")) {
            config.tabs.status.center = parseSegments(runtime, allocator);
            runtime.pop();
        }
        if (runtime.pushTable(-1, "right")) {
            config.tabs.status.right = parseSegments(runtime, allocator);
            runtime.pop();
        }
        runtime.pop();
    }
}

fn parseSegments(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const Segment {
    var list = std.ArrayList(Segment).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseSegment(runtime, allocator)) |mod| {
                list.append(allocator, mod) catch {};
            }
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]Segment{};
}

fn parseSegment(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?Segment {
    return parseSegmentWithDefaultName(runtime, allocator, null);
}

fn parseSpinner(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?SpinnerDef {
    const ty = runtime.fieldType(-1, "spinner");
    if (ty == .nil) return null;
    if (ty != .table) {
        setParseError(allocator, "config: spinner must be a table");
        return null;
    }
    if (!runtime.pushTable(-1, "spinner")) return null;
    defer runtime.pop();

    var s = SpinnerDef{};
    // Always allocate kind so deinit is safe.
    const kind = runtime.getString(-1, "kind") orelse "knight_rider";
    s.kind = allocator.dupe(u8, kind) catch return null;

    if (runtime.getInt(u8, -1, "width")) |v| s.width = v;
    if (runtime.getInt(u64, -1, "step")) |v| s.step_ms = v;
    if (runtime.getInt(u8, -1, "hold")) |v| s.hold_frames = v;
    if (runtime.getInt(u8, -1, "trail")) |v| s.trail_len = v;
    if (runtime.getInt(u8, -1, "bg")) |v| s.bg_color = v;
    if (runtime.getInt(u8, -1, "placeholder")) |v| s.placeholder_color = v;

    if (runtime.pushTable(-1, "colors")) {
        defer runtime.pop();
        var list = std.ArrayList(u8).empty;
        const len = runtime.getArrayLen(-1);
        for (1..len + 1) |i| {
            if (runtime.pushArrayElement(-1, i)) {
                if (runtime.toIntAt(u8, -1)) |cv| {
                    list.append(allocator, cv) catch {};
                }
                runtime.pop();
            }
        }
        if (list.items.len >= 2) {
            s.colors = list.toOwnedSlice(allocator) catch s.colors;
        }
    }

    return s;
}

/// Parse a 'when' condition using the unified Option C syntax.
///
/// Supported forms:
/// - when = "token"                                   -- single token (implicit all)
/// - when = { all = { "a", "b" } }                    -- AND of tokens
/// - when = { any = { "a", "b" } }                    -- OR of tokens (each as single-token all)
/// - when = { any = { { all = {"a","b"} }, "c" } }    -- OR of conditions
/// - when = { bash = "..." }                          -- bash script
/// - when = { lua = "..." }                           -- lua function
fn parseWhenTable(runtime: *LuaRuntime, allocator: std.mem.Allocator, allow_hexe: bool) ?WhenDef {
    _ = allow_hexe; // No longer used; tokens are namespace-agnostic
    const ty = runtime.fieldType(-1, "when");
    if (ty == .nil) return null;

    // String shorthand: when = "token" → { all = { "token" } }
    if (ty == .string) {
        if (runtime.getStringAlloc(-1, "when")) |s| {
            const arr = allocator.alloc([]const u8, 1) catch {
                allocator.free(s);
                return null;
            };
            arr[0] = s;
            return .{ .all = arr };
        }
        return null;
    }

    if (ty != .table) {
        setParseError(allocator, "config: 'when' must be a string or table");
        return null;
    }

    if (!runtime.pushTable(-1, "when")) return null;
    defer runtime.pop();

    return parseWhenExpr(runtime, allocator);
}

/// Parse a when expression (the table is already on the stack).
fn parseWhenExpr(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?WhenDef {
    var when: WhenDef = .{};

    // Check for bash/lua script conditions
    when.bash = runtime.getStringAlloc(-1, "bash");
    when.lua = runtime.getStringAlloc(-1, "lua");

    // Check for 'all' key: array of tokens (AND)
    if (runtime.pushTable(-1, "all")) {
        defer runtime.pop();
        when.all = parseTokenArray(runtime, allocator);
    }

    // Check for 'any' key: array of expressions (OR)
    if (runtime.pushTable(-1, "any")) {
        defer runtime.pop();
        when.any = parseAnyArray(runtime, allocator);
    }

    // If nothing was set, return null
    if (when.all == null and when.any == null and when.bash == null and when.lua == null) {
        return null;
    }

    return when;
}

/// Parse an array of string tokens for 'all' clause.
fn parseTokenArray(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?[][]const u8 {
    const len = runtime.getArrayLen(-1);
    if (len == 0) return null;

    var list = std.ArrayList([]const u8).empty;
    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (runtime.toStringAt(-1)) |s| {
                const dup = allocator.dupe(u8, s) catch null;
                if (dup) |d| {
                    list.append(allocator, d) catch allocator.free(d);
                }
            }
            runtime.pop();
        }
    }

    if (list.items.len == 0) return null;
    return list.toOwnedSlice(allocator) catch null;
}

/// Parse an array of expressions for 'any' clause.
/// Each element can be:
/// - A string: treated as single-token condition
/// - A table: parsed recursively as WhenDef
fn parseAnyArray(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?[]const WhenDef {
    const len = runtime.getArrayLen(-1);
    if (len == 0) return null;

    var list = std.ArrayList(WhenDef).empty;
    for (1..len + 1) |i| {
        if (!runtime.pushArrayElement(-1, i)) continue;
        defer runtime.pop();

        const elem_ty = runtime.typeOf(-1);
        if (elem_ty == .string) {
            // String element: wrap in single-token all
            if (runtime.toStringAt(-1)) |s| {
                const dup = allocator.dupe(u8, s) catch continue;
                const arr = allocator.alloc([]const u8, 1) catch {
                    allocator.free(dup);
                    continue;
                };
                arr[0] = dup;
                list.append(allocator, .{ .all = arr }) catch {
                    allocator.free(dup);
                    allocator.free(arr);
                };
            }
        } else if (elem_ty == .table) {
            // Table element: parse recursively
            if (parseWhenExpr(runtime, allocator)) |w| {
                list.append(allocator, w) catch {
                    var mw = w;
                    @constCast(&mw).deinit(allocator);
                };
            }
        }
    }

    if (list.items.len == 0) return null;
    return list.toOwnedSlice(allocator) catch null;
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

// ===== Ses config parsing =====

fn parseSesConfig(runtime: *LuaRuntime, config: *SesConfig, allocator: std.mem.Allocator) void {
    // Parse layouts array
    if (runtime.pushTable(-1, "layouts")) {
        config.layouts = parseLayouts(runtime, allocator);
        runtime.pop();
    }
}

fn parseLayouts(runtime: *LuaRuntime, allocator: std.mem.Allocator) []LayoutDef {
    var layout_list = std.ArrayList(LayoutDef).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (!runtime.pushArrayElement(-1, i)) continue;
        defer runtime.pop();

        const layout_name = runtime.getString(-1, "name") orelse continue;
        const name = allocator.dupe(u8, layout_name) catch continue;

        const enabled = runtime.getBool(-1, "enabled") orelse false;

        // Parse tabs array
        var tabs: []LayoutTabDef = &[_]LayoutTabDef{};
        if (runtime.pushTable(-1, "tabs")) {
            tabs = parseLayoutTabs(runtime, allocator);
            runtime.pop();
        }

        // Parse floats array
        var floats: []LayoutFloatDef = &[_]LayoutFloatDef{};
        if (runtime.pushTable(-1, "floats")) {
            floats = parseLayoutFloats(runtime, allocator);
            runtime.pop();
        }

        layout_list.append(allocator, .{
            .name = name,
            .enabled = enabled,
            .tabs = tabs,
            .floats = floats,
        }) catch {
            allocator.free(name);
            continue;
        };
    }

    return layout_list.toOwnedSlice(allocator) catch &[_]LayoutDef{};
}

fn parseLayoutTabs(runtime: *LuaRuntime, allocator: std.mem.Allocator) []LayoutTabDef {
    var tab_list = std.ArrayList(LayoutTabDef).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (!runtime.pushArrayElement(-1, i)) continue;
        defer runtime.pop();

        const tab_name = runtime.getString(-1, "name") orelse continue;
        const name = allocator.dupe(u8, tab_name) catch continue;

        const enabled = runtime.getBool(-1, "enabled") orelse true;

        // Parse root split if present
        var root: ?LayoutSplitDef = null;
        if (runtime.pushTable(-1, "root")) {
            root = parseLayoutSplit(runtime, allocator);
            runtime.pop();
        }

        tab_list.append(allocator, .{
            .name = name,
            .enabled = enabled,
            .root = root,
        }) catch {
            allocator.free(name);
            continue;
        };
    }

    return tab_list.toOwnedSlice(allocator) catch &[_]LayoutTabDef{};
}

fn parseLayoutFloats(runtime: *LuaRuntime, allocator: std.mem.Allocator) []LayoutFloatDef {
    var float_list = std.ArrayList(LayoutFloatDef).empty;

    const len = runtime.getArrayLen(-1);
    for (1..len + 1) |i| {
        if (!runtime.pushArrayElement(-1, i)) continue;
        defer runtime.pop();

        const key_str = runtime.getString(-1, "key") orelse continue;
        if (key_str.len == 0) continue;
        const key = key_str[0];

        const enabled = runtime.getBool(-1, "enabled") orelse true;
        const command = runtime.getStringAlloc(-1, "command");
        const title = runtime.getStringAlloc(-1, "title");

        // Parse attributes
        var attrs = FloatAttributes{};
        if (runtime.pushTable(-1, "attributes")) {
            if (runtime.getBool(-1, "exclusive")) |v| attrs.exclusive = v;
            if (runtime.getBool(-1, "per_cwd")) |v| attrs.per_cwd = v;
            if (runtime.getBool(-1, "sticky")) |v| attrs.sticky = v;
            if (runtime.getBool(-1, "global")) |v| attrs.global = v;
            if (runtime.getBool(-1, "destroy")) |v| attrs.destroy = v;
            if (runtime.getBool(-1, "isolated")) |v| attrs.isolated = v;
            runtime.pop();
        }

        // Parse size, position, padding, color, style (same as mux float parsing)
        var width: ?u8 = null;
        var height: ?u8 = null;
        var pos_x: ?u8 = null;
        var pos_y: ?u8 = null;
        var pad_x: ?u8 = null;
        var pad_y: ?u8 = null;
        var color: ?BorderColor = null;
        var style: ?FloatStyle = null;

        if (runtime.pushTable(-1, "size")) {
            if (runtime.getInt(u8, -1, "width")) |v| width = constrainPercent(v, 10, 100);
            if (runtime.getInt(u8, -1, "height")) |v| height = constrainPercent(v, 10, 100);
            runtime.pop();
        }

        if (runtime.pushTable(-1, "position")) {
            if (runtime.getInt(u8, -1, "x")) |v| pos_x = constrainPercent(v, 0, 100);
            if (runtime.getInt(u8, -1, "y")) |v| pos_y = constrainPercent(v, 0, 100);
            runtime.pop();
        }

        if (runtime.pushTable(-1, "padding")) {
            if (runtime.getInt(u8, -1, "x")) |v| pad_x = constrainPercent(v, 0, 10);
            if (runtime.getInt(u8, -1, "y")) |v| pad_y = constrainPercent(v, 0, 10);
            runtime.pop();
        }

        if (runtime.pushTable(-1, "color")) {
            var c = BorderColor{};
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
            .enabled = enabled,
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

    return float_list.toOwnedSlice(allocator) catch &[_]LayoutFloatDef{};
}

fn parseLayoutSplit(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?LayoutSplitDef {
    // Check if this is a split (has array elements) or a pane
    const array_len = runtime.getArrayLen(-1);

    if (array_len >= 2) {
        // This is a split with children
        const dir_str = runtime.getString(-1, "dir") orelse "h";
        const dir = allocator.dupe(u8, dir_str) catch return null;

        const ratio_f64 = runtime.getNumber(-1, "ratio") orelse 0.5;
        const ratio: f32 = @floatCast(ratio_f64);

        // Parse first child
        if (!runtime.pushArrayElement(-1, 1)) {
            allocator.free(dir);
            return null;
        }
        const first_child = parseLayoutSplit(runtime, allocator) orelse {
            runtime.pop();
            allocator.free(dir);
            return null;
        };
        runtime.pop();

        const first = allocator.create(LayoutSplitDef) catch {
            allocator.free(dir);
            var fc = first_child;
            fc.deinit(allocator);
            return null;
        };
        first.* = first_child;

        // Parse second child
        if (!runtime.pushArrayElement(-1, 2)) {
            allocator.free(dir);
            first.deinit(allocator);
            allocator.destroy(first);
            return null;
        }
        const second_child = parseLayoutSplit(runtime, allocator) orelse {
            runtime.pop();
            allocator.free(dir);
            first.deinit(allocator);
            allocator.destroy(first);
            return null;
        };
        runtime.pop();

        const second = allocator.create(LayoutSplitDef) catch {
            allocator.free(dir);
            first.deinit(allocator);
            allocator.destroy(first);
            var sc = second_child;
            sc.deinit(allocator);
            return null;
        };
        second.* = second_child;

        return LayoutSplitDef{
            .split = .{
                .dir = dir,
                .ratio = ratio,
                .first = first,
                .second = second,
            },
        };
    } else {
        // This is a pane
        const cwd = runtime.getStringAlloc(-1, "cwd");
        const command = runtime.getStringAlloc(-1, "command");

        return LayoutSplitDef{
            .pane = .{
                .cwd = cwd,
                .command = command,
            },
        };
    }
}
