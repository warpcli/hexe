const std = @import("std");
const posix = std.posix;

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

        const path = getConfigPath(allocator) catch return config;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return config;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return config;
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(JsonConfig, allocator, content, .{}) catch return config;
        defer parsed.deinit();

        const json = parsed.value;

        // Parse input binds (no legacy key config)
        if (json.input) |inp| {
            if (inp.timing) |t| {
                if (t.hold_ms) |v| config.input.hold_ms = v;
                if (t.repeat_ms) |v| config.input.repeat_ms = v;
                if (t.double_tap_ms) |v| config.input.double_tap_ms = v;
            }
            if (inp.binds) |binds| {
                config.input.binds = parseBinds(allocator, binds);
            }
        }

        // Apply confirmation settings
        if (json.confirm_on_exit) |v| config.confirm_on_exit = v;
        if (json.confirm_on_detach) |v| config.confirm_on_detach = v;
        if (json.confirm_on_disown) |v| config.confirm_on_disown = v;
        if (json.confirm_on_close) |v| config.confirm_on_close = v;

        // Parse panes config
        if (json.tabs) |p| {
            // Status bar
            if (p.status) |s| {
                if (s.enabled) |e| {
                    config.tabs.status.enabled = e;
                }
                if (s.left) |left_mods| {
                    config.tabs.status.left = parseStatusModules(allocator, left_mods);
                }
                if (s.center) |center_mods| {
                    config.tabs.status.center = parseStatusModules(allocator, center_mods);
                }
                if (s.right) |right_mods| {
                    config.tabs.status.right = parseStatusModules(allocator, right_mods);
                }
            }
        }

        // Parse floats array (first keyless entry = defaults)
        if (json.floats) |json_floats| {
            var float_list: std.ArrayList(FloatDef) = .empty;

            // Check for defaults (first entry without key)
            var def_width: ?u8 = null;
            var def_height: ?u8 = null;
            var def_pos_x: ?u8 = null;
            var def_pos_y: ?u8 = null;
            var def_pad_x: ?u8 = null;
            var def_pad_y: ?u8 = null;
            var def_color: ?BorderColor = null;
            var def_style: ?FloatStyle = null;
            var def_attrs = FloatAttributes{};

            for (json_floats, 0..) |jf, idx| {
                // First entry without key = defaults
                if (idx == 0 and jf.key.len == 0) {
                    if (jf.size) |sz| {
                        if (sz.width) |v| def_width = @intCast(@min(100, @max(10, v)));
                        if (sz.height) |v| def_height = @intCast(@min(100, @max(10, v)));
                    }
                    if (jf.width) |v| def_width = @intCast(@min(100, @max(10, v)));
                    if (jf.height) |v| def_height = @intCast(@min(100, @max(10, v)));

                    if (jf.position) |p| {
                        if (p.x) |v| def_pos_x = @intCast(@min(100, @max(0, v)));
                        if (p.y) |v| def_pos_y = @intCast(@min(100, @max(0, v)));
                    }
                    if (jf.pos_x) |v| def_pos_x = @intCast(@min(100, @max(0, v)));
                    if (jf.pos_y) |v| def_pos_y = @intCast(@min(100, @max(0, v)));

                    if (jf.padding) |p| {
                        if (p.x) |v| def_pad_x = @intCast(@min(10, @max(0, v)));
                        if (p.y) |v| def_pad_y = @intCast(@min(10, @max(0, v)));
                    }
                    if (jf.padding_x) |v| def_pad_x = @intCast(@min(10, @max(0, v)));
                    if (jf.padding_y) |v| def_pad_y = @intCast(@min(10, @max(0, v)));

                    const border_color = if (jf.style) |st| if (st.border) |b| b.color else null else null;
                    if (border_color orelse jf.color) |jc| {
                        var c = BorderColor{};
                        if (jc.active) |a| c.active = @intCast(@min(255, @max(0, a)));
                        if (jc.passive) |p| c.passive = @intCast(@min(255, @max(0, p)));
                        def_color = c;
                    }

                    if (jf.style) |js| {
                        def_style = parseFloatStyle(allocator, js);
                    }
                    if (jf.attributes) |a| {
                        if (a.exclusive orelse a.alone) |v| def_attrs.exclusive = v;
                        if (a.per_cwd orelse a.pwd) |v| def_attrs.per_cwd = v;
                        if (a.sticky) |v| def_attrs.sticky = v;
                        if (a.global orelse a.special) |v| def_attrs.global = v;
                        if (a.destroy orelse a.destroy_on_hide) |v| def_attrs.destroy = v;
                        if (def_attrs.destroy and a.global == null and a.special == null) {
                            def_attrs.global = false;
                        }
                    }
                    // Apply defaults to config
                    if (def_width) |w| config.float_width_percent = w;
                    if (def_height) |h| config.float_height_percent = h;
                    if (def_pad_x) |p| config.float_padding_x = p;
                    if (def_pad_y) |p| config.float_padding_y = p;
                    if (def_color) |c| config.float_color = c;
                    if (def_style) |s| config.float_style_default = s;
                    continue;
                }

                const key: u8 = if (jf.key.len > 0) jf.key[0] else continue;
                const command: ?[]const u8 = if (jf.command) |cmd|
                    allocator.dupe(u8, cmd) catch null
                else
                    null;

                // Parse color if present
                const border_color = if (jf.style) |st| if (st.border) |b| b.color else null else null;
                const color: ?BorderColor = if (border_color orelse jf.color) |jc| blk: {
                    var c = BorderColor{};
                    if (jc.active) |a| c.active = @intCast(@min(255, @max(0, a)));
                    if (jc.passive) |p| c.passive = @intCast(@min(255, @max(0, p)));
                    break :blk c;
                } else null;

                // Parse style if present
                const style: ?FloatStyle = if (jf.style) |js| parseFloatStyle(allocator, js) else null;

                var attrs = def_attrs;
                if (jf.attributes) |a| {
                    if (a.exclusive orelse a.alone) |v| attrs.exclusive = v;
                    if (a.per_cwd orelse a.pwd) |v| attrs.per_cwd = v;
                    if (a.sticky) |v| attrs.sticky = v;
                    if (a.destroy orelse a.destroy_on_hide) |v| attrs.destroy = v;
                    if (a.global orelse a.special) |v| attrs.global = v;
                    // If destroy is set and global not explicitly provided, default global to false.
                    if (attrs.destroy and a.global == null and a.special == null) {
                        attrs.global = false;
                    }
                }

                float_list.append(allocator, .{
                    .key = key,
                    .command = command,
                    .title = if (jf.title) |t| allocator.dupe(u8, t) catch null else null,
                    .attributes = attrs,
                    .width_percent = if (if (jf.size) |sz| sz.width else null) |v| @intCast(@min(100, @max(10, v))) else if (jf.width) |v| @intCast(@min(100, @max(10, v))) else def_width,
                    .height_percent = if (if (jf.size) |sz| sz.height else null) |v| @intCast(@min(100, @max(10, v))) else if (jf.height) |v| @intCast(@min(100, @max(10, v))) else def_height,
                    .pos_x = if (if (jf.position) |p| p.x else null) |v| @intCast(@min(100, @max(0, v))) else if (jf.pos_x) |v| @intCast(@min(100, @max(0, v))) else def_pos_x,
                    .pos_y = if (if (jf.position) |p| p.y else null) |v| @intCast(@min(100, @max(0, v))) else if (jf.pos_y) |v| @intCast(@min(100, @max(0, v))) else def_pos_y,
                    .padding_x = if (if (jf.padding) |p| p.x else null) |v| @intCast(@min(10, @max(0, v))) else if (jf.padding_x) |v| @intCast(@min(10, @max(0, v))) else def_pad_x,
                    .padding_y = if (if (jf.padding) |p| p.y else null) |v| @intCast(@min(10, @max(0, v))) else if (jf.padding_y) |v| @intCast(@min(10, @max(0, v))) else def_pad_y,
                    .color = color orelse def_color,
                    .style = style orelse def_style,
                }) catch continue;
            }
            config.floats = float_list.toOwnedSlice(allocator) catch &[_]FloatDef{};
        }

        // Parse splits config
        if (json.splits) |sp| {
            // Color
            if (sp.color) |jc| {
                if (jc.active) |a| config.splits.color.active = @intCast(@min(255, @max(0, a)));
                if (jc.passive) |p| config.splits.color.passive = @intCast(@min(255, @max(0, p)));
            }
            // Simple separators
            if (sp.separator_v) |s| if (s.len > 0) {
                config.splits.separator_v = std.unicode.utf8Decode(s) catch 0x2502;
            };
            if (sp.separator_h) |s| if (s.len > 0) {
                config.splits.separator_h = std.unicode.utf8Decode(s) catch 0x2500;
            };
            // Full style
            if (sp.style) |js| {
                var style = SplitStyle{};
                if (js.vertical) |s| if (s.len > 0) {
                    style.vertical = std.unicode.utf8Decode(s) catch 0x2502;
                };
                if (js.horizontal) |s| if (s.len > 0) {
                    style.horizontal = std.unicode.utf8Decode(s) catch 0x2500;
                };
                if (js.cross) |s| if (s.len > 0) {
                    style.cross = std.unicode.utf8Decode(s) catch 0x253C;
                };
                if (js.top_t) |s| if (s.len > 0) {
                    style.top_t = std.unicode.utf8Decode(s) catch 0x252C;
                };
                if (js.bottom_t) |s| if (s.len > 0) {
                    style.bottom_t = std.unicode.utf8Decode(s) catch 0x2534;
                };
                if (js.left_t) |s| if (s.len > 0) {
                    style.left_t = std.unicode.utf8Decode(s) catch 0x251C;
                };
                if (js.right_t) |s| if (s.len > 0) {
                    style.right_t = std.unicode.utf8Decode(s) catch 0x2524;
                };
                config.splits.style = style;
            }
        }

        // Parse notifications config (dual-realm: mux and pane)
        if (json.notifications) |n| {
            // Parse mux realm config
            if (n.mux) |m| {
                if (m.fg) |v| config.notifications.mux.fg = @intCast(@min(255, @max(0, v)));
                if (m.bg) |v| config.notifications.mux.bg = @intCast(@min(255, @max(0, v)));
                if (m.bold) |v| config.notifications.mux.bold = v;
                if (m.padding_x) |v| config.notifications.mux.padding_x = @intCast(@min(10, @max(0, v)));
                if (m.padding_y) |v| config.notifications.mux.padding_y = @intCast(@min(10, @max(0, v)));
                if (m.offset) |v| config.notifications.mux.offset = @intCast(@min(20, @max(0, v)));
                if (m.duration_ms) |v| config.notifications.mux.duration_ms = @intCast(@min(60000, @max(100, v)));
                if (m.alignment) |v| config.notifications.mux.alignment = allocator.dupe(u8, v) catch "center";
            }
            // Parse pane realm config
            if (n.pane) |p| {
                if (p.fg) |v| config.notifications.pane.fg = @intCast(@min(255, @max(0, v)));
                if (p.bg) |v| config.notifications.pane.bg = @intCast(@min(255, @max(0, v)));
                if (p.bold) |v| config.notifications.pane.bold = v;
                if (p.padding_x) |v| config.notifications.pane.padding_x = @intCast(@min(10, @max(0, v)));
                if (p.padding_y) |v| config.notifications.pane.padding_y = @intCast(@min(10, @max(0, v)));
                if (p.offset) |v| config.notifications.pane.offset = @intCast(@min(20, @max(0, v)));
                if (p.duration_ms) |v| config.notifications.pane.duration_ms = @intCast(@min(60000, @max(100, v)));
                if (p.alignment) |v| config.notifications.pane.alignment = allocator.dupe(u8, v) catch "center";
            }
        }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._allocator) |alloc| {
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

    fn parseBinds(allocator: std.mem.Allocator, json_binds: []const JsonBind) []const Bind {
        var list: std.ArrayList(Bind) = .empty;

        for (json_binds) |jb| {
            const mods_mask = modsMaskFromStrings(jb.mods);

            const when: BindWhen = if (jb.when) |w|
                (std.meta.stringToEnum(BindWhen, w) orelse .press)
            else
                .press;

            const key: BindKey = blk: {
                if (jb.key.len == 1) break :blk .{ .char = jb.key[0] };
                if (std.mem.eql(u8, jb.key, "space")) break :blk .space;
                if (std.mem.eql(u8, jb.key, "up")) break :blk .up;
                if (std.mem.eql(u8, jb.key, "down")) break :blk .down;
                if (std.mem.eql(u8, jb.key, "left")) break :blk .left;
                if (std.mem.eql(u8, jb.key, "right")) break :blk .right;
                // Unknown -> skip
                continue;
            };

            var ctx = BindContext{};
            if (jb.context) |c| {
                if (c.focus) |f| {
                    ctx.focus = std.meta.stringToEnum(FocusContext, f) orelse .any;
                }
            }

            const action: BindAction = blk: {
                const t = jb.action.type;
                if (std.mem.eql(u8, t, "mux.quit")) break :blk .mux_quit;
                if (std.mem.eql(u8, t, "mux.detach")) break :blk .mux_detach;
                if (std.mem.eql(u8, t, "pane.disown")) break :blk .pane_disown;
                if (std.mem.eql(u8, t, "pane.adopt")) break :blk .pane_adopt;
                if (std.mem.eql(u8, t, "split.h")) break :blk .split_h;
                if (std.mem.eql(u8, t, "split.v")) break :blk .split_v;
                if (std.mem.eql(u8, t, "split.resize")) {
                    const dir = jb.action.dir orelse continue;
                    const d = std.meta.stringToEnum(BindKeyKind, dir) orelse continue;
                    if (d != .up and d != .down and d != .left and d != .right) continue;
                    break :blk .{ .split_resize = d };
                }
                if (std.mem.eql(u8, t, "tab.new")) break :blk .tab_new;
                if (std.mem.eql(u8, t, "tab.next")) break :blk .tab_next;
                if (std.mem.eql(u8, t, "tab.prev")) break :blk .tab_prev;
                if (std.mem.eql(u8, t, "tab.close")) break :blk .tab_close;
                if (std.mem.eql(u8, t, "float.toggle")) {
                    const fk = jb.action.float orelse continue;
                    if (fk.len != 1) continue;
                    break :blk .{ .float_toggle = fk[0] };
                }
                if (std.mem.eql(u8, t, "float.nudge")) {
                    const dir = jb.action.dir orelse continue;
                    const d = std.meta.stringToEnum(BindKeyKind, dir) orelse continue;
                    if (d != .up and d != .down and d != .left and d != .right) continue;
                    break :blk .{ .float_nudge = d };
                }
                if (std.mem.eql(u8, t, "focus.move")) {
                    const dir = jb.action.dir orelse continue;
                    const d = std.meta.stringToEnum(BindKeyKind, dir) orelse continue;
                    if (d != .up and d != .down and d != .left and d != .right) continue;
                    break :blk .{ .focus_move = d };
                }
                continue;
            };

            list.append(allocator, .{
                .when = when,
                .mods = mods_mask,
                .key = key,
                .context = ctx,
                .action = action,
                .hold_ms = jb.hold_ms,
                .double_tap_ms = jb.double_tap_ms,
            }) catch continue;
        }

        return list.toOwnedSlice(allocator) catch &[_]Bind{};
    }

    fn parseStatusModules(allocator: std.mem.Allocator, json_mods: []const JsonStatusModule) []const StatusModule {
        var list: std.ArrayList(StatusModule) = .empty;
        for (json_mods) |jm| {
            // Parse outputs array
            var outputs: []const OutputDef = &[_]OutputDef{};
            if (jm.outputs) |json_outputs| {
                var output_list: std.ArrayList(OutputDef) = .empty;
                for (json_outputs) |jo| {
                    output_list.append(allocator, .{
                        .style = if (jo.style) |s| allocator.dupe(u8, s) catch "" else "",
                        .format = if (jo.format) |f| allocator.dupe(u8, f) catch "$output" else "$output",
                    }) catch continue;
                }
                outputs = output_list.toOwnedSlice(allocator) catch &[_]OutputDef{};
            }

            list.append(allocator, .{
                .name = allocator.dupe(u8, jm.name) catch continue,
                .priority = if (jm.priority) |p| @intCast(@max(1, @min(255, p))) else 50,
                .outputs = outputs,
                .command = if (jm.command) |c| allocator.dupe(u8, c) catch null else null,
                .when = if (jm.when) |w| allocator.dupe(u8, w) catch null else null,
                .active_style = if (jm.active_style) |s| allocator.dupe(u8, s) catch "bg:1 fg:0" else "bg:1 fg:0",
                .inactive_style = if (jm.inactive_style) |s| allocator.dupe(u8, s) catch "bg:237 fg:250" else "bg:237 fg:250",
                .separator = if (jm.separator) |s| allocator.dupe(u8, s) catch " | " else " | ",
                .separator_style = if (jm.separator_style) |s| allocator.dupe(u8, s) catch "fg:7" else "fg:7",
                .tab_title = if (jm.tab_title) |s| allocator.dupe(u8, s) catch "basename" else "basename",
                .left_arrow = if (jm.left_arrow) |s| allocator.dupe(u8, s) catch "" else "",
                .right_arrow = if (jm.right_arrow) |s| allocator.dupe(u8, s) catch "" else "",
            }) catch continue;
        }
        return list.toOwnedSlice(allocator) catch &[_]StatusModule{};
    }

    fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
        const config_home = posix.getenv("XDG_CONFIG_HOME");
        if (config_home) |ch| {
            return std.fmt.allocPrint(allocator, "{s}/hexe/mux.json", .{ch});
        }

        const home = posix.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/.config/hexe/mux.json", .{home});
    }
};

// JSON structure for parsing
const JsonBorderColor = struct {
    active: ?i64 = null,
    passive: ?i64 = null,
};
const JsonXY = struct {
    x: ?i64 = null,
    y: ?i64 = null,
};
const JsonSize = struct {
    width: ?i64 = null,
    height: ?i64 = null,
};
const JsonFloatStyle = struct {
    // Legacy border appearance (still accepted)
    top_left: ?[]const u8 = null,
    top_right: ?[]const u8 = null,
    bottom_left: ?[]const u8 = null,
    bottom_right: ?[]const u8 = null,
    horizontal: ?[]const u8 = null,
    vertical: ?[]const u8 = null,
    // Legacy title module (still accepted)
    position: ?[]const u8 = null, // topleft, topcenter, topright, bottomleft, bottomcenter, bottomright
    name: ?[]const u8 = null, // module name (e.g. "time", "cpu")
    outputs: ?[]const JsonOutput = null,
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,

    // New hierarchical style config
    border: ?struct {
        color: ?JsonBorderColor = null,
        chars: ?struct {
            top_left: ?[]const u8 = null,
            top_right: ?[]const u8 = null,
            bottom_left: ?[]const u8 = null,
            bottom_right: ?[]const u8 = null,
            horizontal: ?[]const u8 = null,
            vertical: ?[]const u8 = null,
            cross: ?[]const u8 = null,
            top_t: ?[]const u8 = null,
            bottom_t: ?[]const u8 = null,
            left_t: ?[]const u8 = null,
            right_t: ?[]const u8 = null,
        } = null,
    } = null,
    shadow: ?struct {
        color: ?i64 = null,
    } = null,
    title: ?struct {
        position: ?[]const u8 = null,
        outputs: ?[]const JsonOutput = null,
        command: ?[]const u8 = null,
        when: ?[]const u8 = null,
    } = null,
};
fn parseFloatStyle(allocator: std.mem.Allocator, js: JsonFloatStyle) ?FloatStyle {
    var result = FloatStyle{};
    const border_chars = if (js.border) |b| b.chars else null;
    if (if (border_chars) |bc| bc.top_left else null) |ch| if (ch.len > 0) {
        result.top_left = std.unicode.utf8Decode(ch) catch 0x256D;
    } else if (js.top_left) |ch2| if (ch2.len > 0) {
        result.top_left = std.unicode.utf8Decode(ch2) catch 0x256D;
    };
    if (if (border_chars) |bc| bc.top_right else null) |ch| if (ch.len > 0) {
        result.top_right = std.unicode.utf8Decode(ch) catch 0x256E;
    } else if (js.top_right) |ch2| if (ch2.len > 0) {
        result.top_right = std.unicode.utf8Decode(ch2) catch 0x256E;
    };
    if (if (border_chars) |bc| bc.bottom_left else null) |ch| if (ch.len > 0) {
        result.bottom_left = std.unicode.utf8Decode(ch) catch 0x2570;
    } else if (js.bottom_left) |ch2| if (ch2.len > 0) {
        result.bottom_left = std.unicode.utf8Decode(ch2) catch 0x2570;
    };
    if (if (border_chars) |bc| bc.bottom_right else null) |ch| if (ch.len > 0) {
        result.bottom_right = std.unicode.utf8Decode(ch) catch 0x256F;
    } else if (js.bottom_right) |ch2| if (ch2.len > 0) {
        result.bottom_right = std.unicode.utf8Decode(ch2) catch 0x256F;
    };
    if (if (border_chars) |bc| bc.horizontal else null) |ch| if (ch.len > 0) {
        result.horizontal = std.unicode.utf8Decode(ch) catch 0x2500;
    } else if (js.horizontal) |ch2| if (ch2.len > 0) {
        result.horizontal = std.unicode.utf8Decode(ch2) catch 0x2500;
    };
    if (if (border_chars) |bc| bc.vertical else null) |ch| if (ch.len > 0) {
        result.vertical = std.unicode.utf8Decode(ch) catch 0x2502;
    } else if (js.vertical) |ch2| if (ch2.len > 0) {
        result.vertical = std.unicode.utf8Decode(ch2) catch 0x2502;
    };

    if (if (border_chars) |bc| bc.cross else null) |ch| if (ch.len > 0) {
        result.cross = std.unicode.utf8Decode(ch) catch 0x253C;
    };
    if (if (border_chars) |bc| bc.top_t else null) |ch| if (ch.len > 0) {
        result.top_t = std.unicode.utf8Decode(ch) catch 0x252C;
    };
    if (if (border_chars) |bc| bc.bottom_t else null) |ch| if (ch.len > 0) {
        result.bottom_t = std.unicode.utf8Decode(ch) catch 0x2534;
    };
    if (if (border_chars) |bc| bc.left_t else null) |ch| if (ch.len > 0) {
        result.left_t = std.unicode.utf8Decode(ch) catch 0x251C;
    };
    if (if (border_chars) |bc| bc.right_t else null) |ch| if (ch.len > 0) {
        result.right_t = std.unicode.utf8Decode(ch) catch 0x2524;
    };

    if (js.shadow) |sh| {
        if (sh.color) |c| {
            result.shadow_color = @intCast(@min(255, @max(0, c)));
        }
    }

    const title_pos = if (js.title) |t| t.position else null;
    if (title_pos) |pos_str| {
        result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
    } else if (js.position) |pos_str| {
        result.position = std.meta.stringToEnum(FloatStylePosition, pos_str);
    }

    // Title widget: either legacy `name` or new `style.title` section.
    const has_title_cfg = (js.title != null) or (js.outputs != null) or (js.command != null) or (js.when != null);
    const default_name: []const u8 = "";
    const mod_name = js.name orelse (if (has_title_cfg) default_name else null);
    if (mod_name) |mn| {
        var outputs: []const OutputDef = &[_]OutputDef{};
        const title_outputs = if (js.title) |t| t.outputs else null;
        const legacy_outputs = js.outputs;
        const outputs_src = title_outputs orelse legacy_outputs;
        if (outputs_src) |json_outputs| {
            var output_list: std.ArrayList(OutputDef) = .empty;
            for (json_outputs) |jo| {
                output_list.append(allocator, .{
                    .style = if (jo.style) |st| allocator.dupe(u8, st) catch "" else "",
                    .format = if (jo.format) |ft| allocator.dupe(u8, ft) catch "$output" else "$output",
                }) catch continue;
            }
            outputs = output_list.toOwnedSlice(allocator) catch &[_]OutputDef{};
        }

        const cmd_src = if (js.title) |t| t.command else js.command;
        const when_src = if (js.title) |t| t.when else js.when;
        result.module = .{
            .name = allocator.dupe(u8, mn) catch "",
            .outputs = outputs,
            .command = if (cmd_src) |cmd| allocator.dupe(u8, cmd) catch null else null,
            .when = if (when_src) |w| allocator.dupe(u8, w) catch null else null,
        };
    }

    return result;
}

const JsonFloatPane = struct {
    key: []const u8 = "",
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
    attributes: ?struct {
        // Preferred names
        exclusive: ?bool = null,
        per_cwd: ?bool = null,
        sticky: ?bool = null,
        global: ?bool = null,
        destroy: ?bool = null,
        // Legacy names (still accepted inside attributes)
        alone: ?bool = null,
        pwd: ?bool = null,
        special: ?bool = null,
        destroy_on_hide: ?bool = null,
    } = null,
    // Legacy flat fields (still accepted)
    width: ?i64 = null,
    height: ?i64 = null,
    pos_x: ?i64 = null,
    pos_y: ?i64 = null,
    padding_x: ?i64 = null,
    padding_y: ?i64 = null,
    color: ?JsonBorderColor = null,

    // New hierarchical fields
    size: ?JsonSize = null,
    position: ?JsonXY = null,
    padding: ?JsonXY = null,

    style: ?JsonFloatStyle = null,
};

const JsonSplitStyle = struct {
    vertical: ?[]const u8 = null,
    horizontal: ?[]const u8 = null,
    cross: ?[]const u8 = null,
    top_t: ?[]const u8 = null,
    bottom_t: ?[]const u8 = null,
    left_t: ?[]const u8 = null,
    right_t: ?[]const u8 = null,
};

const JsonSplitsConfig = struct {
    color: ?JsonBorderColor = null,
    separator_v: ?[]const u8 = null,
    separator_h: ?[]const u8 = null,
    style: ?JsonSplitStyle = null,
};

const JsonTabsConfig = struct {
    status: ?struct {
        enabled: ?bool = null,
        left: ?[]const JsonStatusModule = null,
        center: ?[]const JsonStatusModule = null,
        right: ?[]const JsonStatusModule = null,
    } = null,
};

const JsonNotificationStyleConfig = struct {
    fg: ?i64 = null,
    bg: ?i64 = null,
    bold: ?bool = null,
    padding_x: ?i64 = null,
    padding_y: ?i64 = null,
    offset: ?i64 = null,
    alignment: ?[]const u8 = null,
    duration_ms: ?i64 = null,
};
const JsonNotificationConfig = struct {
    mux: ?JsonNotificationStyleConfig = null,
    pane: ?JsonNotificationStyleConfig = null,
};
const JsonConfig = struct {
    input: ?struct {
        timing: ?struct {
            hold_ms: ?i64 = null,
            repeat_ms: ?i64 = null,
            double_tap_ms: ?i64 = null,
        } = null,
        binds: ?[]const JsonBind = null,
    } = null,
    confirm_on_exit: ?bool = null,
    confirm_on_detach: ?bool = null,
    confirm_on_disown: ?bool = null,
    confirm_on_close: ?bool = null,
    floats: ?[]const JsonFloatPane = null,
    splits: ?JsonSplitsConfig = null,
    tabs: ?JsonTabsConfig = null,
    notifications: ?JsonNotificationConfig = null,
};

const JsonBind = struct {
    when: ?[]const u8 = null,
    mods: ?[]const []const u8 = null,
    key: []const u8,
    hold_ms: ?i64 = null,
    double_tap_ms: ?i64 = null,
    context: ?struct {
        focus: ?[]const u8 = null,
    } = null,
    action: struct {
        type: []const u8,
        // for float_toggle
        float: ?[]const u8 = null,
        // for float_nudge
        // for float_nudge / focus_move / split_resize
        dir: ?[]const u8 = null,
    },
};

const JsonOutput = struct {
    style: ?[]const u8 = null,
    format: ?[]const u8 = null,
};

const JsonStatusModule = struct {
    name: []const u8,
    priority: ?i64 = null,
    outputs: ?[]const JsonOutput = null,
    command: ?[]const u8 = null,
    when: ?[]const u8 = null,
    active_style: ?[]const u8 = null,
    inactive_style: ?[]const u8 = null,
    separator: ?[]const u8 = null,
    separator_style: ?[]const u8 = null,
    tab_title: ?[]const u8 = null,
    left_arrow: ?[]const u8 = null,
    right_arrow: ?[]const u8 = null,
};
