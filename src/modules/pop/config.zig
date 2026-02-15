const std = @import("std");
const core = @import("core");
const lua_runtime = core.lua_runtime;
const LuaRuntime = core.LuaRuntime;
const ConfigStatus = core.ConfigStatus;
const widgets = @import("widgets/mod.zig");

/// Notification style configuration
pub const NotificationStyle = struct {
    fg: u8 = 0, // foreground color (palette index)
    bg: u8 = 3, // background color (palette index)
    bold: bool = true,
    padding_x: u8 = 1, // horizontal padding inside box
    padding_y: u8 = 0, // vertical padding inside box
    offset: u8 = 1, // offset from edge
    alignment: []const u8 = "center", // horizontal alignment: left, center, right
    duration_ms: u32 = 3000,
};

/// Confirm dialog style configuration
pub const ConfirmStyle = struct {
    fg: u8 = 0,
    bg: u8 = 4, // blue
    bold: bool = true,
    padding_x: u8 = 2,
    padding_y: u8 = 1,
    yes_label: []const u8 = "Yes",
    no_label: []const u8 = "No",
};

/// Choose/Picker dialog style configuration
pub const ChooseStyle = struct {
    fg: u8 = 7,
    bg: u8 = 0, // black
    highlight_fg: u8 = 0,
    highlight_bg: u8 = 7,
    bold: bool = false,
    padding_x: u8 = 1,
    padding_y: u8 = 0,
    visible_count: u8 = 10,
};

/// Carrier scope settings (MUX + TAB - same settings)
pub const CarrierConfig = struct {
    notification: NotificationStyle = .{
        .offset = 1,
    },
    confirm: ConfirmStyle = .{},
    choose: ChooseStyle = .{},
};

/// Pane scope settings
pub const PaneConfig = struct {
    notification: NotificationStyle = .{
        .offset = 0,
    },
    confirm: ConfirmStyle = .{},
    choose: ChooseStyle = .{},
};

/// Pop configuration - loaded from ~/.config/hexe/pop.lua
pub const PopConfig = struct {
    carrier: CarrierConfig = .{},
    pane: PaneConfig = .{},
    widgets: widgets.WidgetsConfig = .{},
    status: ConfigStatus = .loaded,
    status_message: ?[]const u8 = null,

    _allocator: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) PopConfig {
        var config = PopConfig{};
        config._allocator = allocator;

        const path = lua_runtime.getConfigPath(allocator, "init.lua") catch return config;
        defer allocator.free(path);

        var runtime = LuaRuntime.init(allocator) catch {
            config.status = .@"error";
            config.status_message = allocator.dupe(u8, "failed to initialize Lua") catch null;
            return config;
        };
        defer runtime.deinit();

        // Let a single config.lua avoid building other sections.
        runtime.setHexeSection("pop");

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

        // Use ConfigBuilder API approach
        if (runtime.getBuilder()) |builder| {
            if (builder.pop) |pop_builder| {
                // Build carrier notification config
                if (pop_builder.carrier_notification) |notif| {
                    if (notif.fg) |v| config.carrier.notification.fg = v;
                    if (notif.bg) |v| config.carrier.notification.bg = v;
                    if (notif.bold) |v| config.carrier.notification.bold = v;
                    if (notif.padding_x) |v| config.carrier.notification.padding_x = v;
                    if (notif.padding_y) |v| config.carrier.notification.padding_y = v;
                    if (notif.offset) |v| config.carrier.notification.offset = v;
                    if (notif.duration_ms) |v| config.carrier.notification.duration_ms = v;
                    if (notif.alignment) |a| config.carrier.notification.alignment = a;
                }

                // Build pane notification config
                if (pop_builder.pane_notification) |notif| {
                    if (notif.fg) |v| config.pane.notification.fg = v;
                    if (notif.bg) |v| config.pane.notification.bg = v;
                    if (notif.bold) |v| config.pane.notification.bold = v;
                    if (notif.padding_x) |v| config.pane.notification.padding_x = v;
                    if (notif.padding_y) |v| config.pane.notification.padding_y = v;
                    if (notif.offset) |v| config.pane.notification.offset = v;
                    if (notif.duration_ms) |v| config.pane.notification.duration_ms = v;
                    if (notif.alignment) |a| config.pane.notification.alignment = a;
                }

                // Build carrier confirm config
                if (pop_builder.carrier_confirm) |conf| {
                    if (conf.fg) |v| config.carrier.confirm.fg = v;
                    if (conf.bg) |v| config.carrier.confirm.bg = v;
                    if (conf.bold) |v| config.carrier.confirm.bold = v;
                    if (conf.padding_x) |v| config.carrier.confirm.padding_x = v;
                    if (conf.padding_y) |v| config.carrier.confirm.padding_y = v;
                    if (conf.yes_label) |y| config.carrier.confirm.yes_label = y;
                    if (conf.no_label) |n| config.carrier.confirm.no_label = n;
                }

                // Build pane confirm config
                if (pop_builder.pane_confirm) |conf| {
                    if (conf.fg) |v| config.pane.confirm.fg = v;
                    if (conf.bg) |v| config.pane.confirm.bg = v;
                    if (conf.bold) |v| config.pane.confirm.bold = v;
                    if (conf.padding_x) |v| config.pane.confirm.padding_x = v;
                    if (conf.padding_y) |v| config.pane.confirm.padding_y = v;
                    if (conf.yes_label) |y| config.pane.confirm.yes_label = y;
                    if (conf.no_label) |n| config.pane.confirm.no_label = n;
                }

                // Build carrier choose config
                if (pop_builder.carrier_choose) |ch| {
                    if (ch.fg) |v| config.carrier.choose.fg = v;
                    if (ch.bg) |v| config.carrier.choose.bg = v;
                    if (ch.highlight_fg) |v| config.carrier.choose.highlight_fg = v;
                    if (ch.highlight_bg) |v| config.carrier.choose.highlight_bg = v;
                    if (ch.bold) |v| config.carrier.choose.bold = v;
                    if (ch.padding_x) |v| config.carrier.choose.padding_x = v;
                    if (ch.padding_y) |v| config.carrier.choose.padding_y = v;
                    if (ch.visible_count) |v| config.carrier.choose.visible_count = v;
                }

                // Build pane choose config
                if (pop_builder.pane_choose) |ch| {
                    if (ch.fg) |v| config.pane.choose.fg = v;
                    if (ch.bg) |v| config.pane.choose.bg = v;
                    if (ch.highlight_fg) |v| config.pane.choose.highlight_fg = v;
                    if (ch.highlight_bg) |v| config.pane.choose.highlight_bg = v;
                    if (ch.bold) |v| config.pane.choose.bold = v;
                    if (ch.padding_x) |v| config.pane.choose.padding_x = v;
                    if (ch.padding_y) |v| config.pane.choose.padding_y = v;
                    if (ch.visible_count) |v| config.pane.choose.visible_count = v;
                }

                // Build widgets config
                if (pop_builder.widgets.pokemon_enabled) |v| config.widgets.pokemon.enabled = v;
                if (pop_builder.widgets.pokemon_position) |p| config.widgets.pokemon.position = parsePosition(p);
                if (pop_builder.widgets.pokemon_shiny_chance) |f| config.widgets.pokemon.shiny_chance = f;
                if (pop_builder.widgets.keycast_enabled) |v| config.widgets.keycast.enabled = v;
                if (pop_builder.widgets.keycast_position) |p| config.widgets.keycast.position = parsePosition(p);
                if (pop_builder.widgets.keycast_duration_ms) |t| config.widgets.keycast.duration_ms = t;
                if (pop_builder.widgets.keycast_max_entries) |m| config.widgets.keycast.max_entries = m;
                if (pop_builder.widgets.keycast_grouping_timeout_ms) |g| config.widgets.keycast.grouping_timeout_ms = g;
                if (pop_builder.widgets.digits_enabled) |v| config.widgets.digits.enabled = v;
                if (pop_builder.widgets.digits_position) |p| config.widgets.digits.position = parsePosition(p);
                if (pop_builder.widgets.digits_size) |s| config.widgets.digits.size = parseDigitSize(s);

                config._allocator = allocator;
            }
        }

        // Pop config return value (if any) from stack
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

        // Use ConfigBuilder API approach for local config (merge/overwrite)
        if (runtime.getBuilder()) |builder| {
            if (builder.pop) |pop_builder| {
                // Build carrier notification config
                if (pop_builder.carrier_notification) |notif| {
                    if (notif.fg) |v| config.carrier.notification.fg = v;
                    if (notif.bg) |v| config.carrier.notification.bg = v;
                    if (notif.bold) |v| config.carrier.notification.bold = v;
                    if (notif.padding_x) |v| config.carrier.notification.padding_x = v;
                    if (notif.padding_y) |v| config.carrier.notification.padding_y = v;
                    if (notif.offset) |v| config.carrier.notification.offset = v;
                    if (notif.duration_ms) |v| config.carrier.notification.duration_ms = v;
                    if (notif.alignment) |a| config.carrier.notification.alignment = a;
                }

                // Build pane notification config
                if (pop_builder.pane_notification) |notif| {
                    if (notif.fg) |v| config.pane.notification.fg = v;
                    if (notif.bg) |v| config.pane.notification.bg = v;
                    if (notif.bold) |v| config.pane.notification.bold = v;
                    if (notif.padding_x) |v| config.pane.notification.padding_x = v;
                    if (notif.padding_y) |v| config.pane.notification.padding_y = v;
                    if (notif.offset) |v| config.pane.notification.offset = v;
                    if (notif.duration_ms) |v| config.pane.notification.duration_ms = v;
                    if (notif.alignment) |a| config.pane.notification.alignment = a;
                }

                // Build carrier confirm config
                if (pop_builder.carrier_confirm) |conf| {
                    if (conf.fg) |v| config.carrier.confirm.fg = v;
                    if (conf.bg) |v| config.carrier.confirm.bg = v;
                    if (conf.bold) |v| config.carrier.confirm.bold = v;
                    if (conf.padding_x) |v| config.carrier.confirm.padding_x = v;
                    if (conf.padding_y) |v| config.carrier.confirm.padding_y = v;
                    if (conf.yes_label) |y| config.carrier.confirm.yes_label = y;
                    if (conf.no_label) |n| config.carrier.confirm.no_label = n;
                }

                // Build pane confirm config
                if (pop_builder.pane_confirm) |conf| {
                    if (conf.fg) |v| config.pane.confirm.fg = v;
                    if (conf.bg) |v| config.pane.confirm.bg = v;
                    if (conf.bold) |v| config.pane.confirm.bold = v;
                    if (conf.padding_x) |v| config.pane.confirm.padding_x = v;
                    if (conf.padding_y) |v| config.pane.confirm.padding_y = v;
                    if (conf.yes_label) |y| config.pane.confirm.yes_label = y;
                    if (conf.no_label) |n| config.pane.confirm.no_label = n;
                }

                // Build carrier choose config
                if (pop_builder.carrier_choose) |ch| {
                    if (ch.fg) |v| config.carrier.choose.fg = v;
                    if (ch.bg) |v| config.carrier.choose.bg = v;
                    if (ch.highlight_fg) |v| config.carrier.choose.highlight_fg = v;
                    if (ch.highlight_bg) |v| config.carrier.choose.highlight_bg = v;
                    if (ch.bold) |v| config.carrier.choose.bold = v;
                    if (ch.padding_x) |v| config.carrier.choose.padding_x = v;
                    if (ch.padding_y) |v| config.carrier.choose.padding_y = v;
                    if (ch.visible_count) |v| config.carrier.choose.visible_count = v;
                }

                // Build pane choose config
                if (pop_builder.pane_choose) |ch| {
                    if (ch.fg) |v| config.pane.choose.fg = v;
                    if (ch.bg) |v| config.pane.choose.bg = v;
                    if (ch.highlight_fg) |v| config.pane.choose.highlight_fg = v;
                    if (ch.highlight_bg) |v| config.pane.choose.highlight_bg = v;
                    if (ch.bold) |v| config.pane.choose.bold = v;
                    if (ch.padding_x) |v| config.pane.choose.padding_x = v;
                    if (ch.padding_y) |v| config.pane.choose.padding_y = v;
                    if (ch.visible_count) |v| config.pane.choose.visible_count = v;
                }

                // Build widgets config
                if (pop_builder.widgets.pokemon_enabled) |v| config.widgets.pokemon.enabled = v;
                if (pop_builder.widgets.pokemon_position) |p| config.widgets.pokemon.position = parsePosition(p);
                if (pop_builder.widgets.pokemon_shiny_chance) |f| config.widgets.pokemon.shiny_chance = f;
                if (pop_builder.widgets.keycast_enabled) |v| config.widgets.keycast.enabled = v;
                if (pop_builder.widgets.keycast_position) |p| config.widgets.keycast.position = parsePosition(p);
                if (pop_builder.widgets.keycast_duration_ms) |t| config.widgets.keycast.duration_ms = t;
                if (pop_builder.widgets.keycast_max_entries) |m| config.widgets.keycast.max_entries = m;
                if (pop_builder.widgets.keycast_grouping_timeout_ms) |g| config.widgets.keycast.grouping_timeout_ms = g;
                if (pop_builder.widgets.digits_enabled) |v| config.widgets.digits.enabled = v;
                if (pop_builder.widgets.digits_position) |p| config.widgets.digits.position = parsePosition(p);
                if (pop_builder.widgets.digits_size) |s| config.widgets.digits.size = parseDigitSize(s);
            }
        }

        // Pop config return value (if any) from stack
        runtime.pop();

        return config;
    }

    pub fn deinit(self: *PopConfig) void {
        // Free any allocated strings if we had an allocator
        _ = self;
    }
};

fn parsePosition(pos_str: []const u8) widgets.Position {
    if (std.mem.eql(u8, pos_str, "topleft")) return .topleft;
    if (std.mem.eql(u8, pos_str, "topright")) return .topright;
    if (std.mem.eql(u8, pos_str, "bottomleft")) return .bottomleft;
    if (std.mem.eql(u8, pos_str, "bottomright")) return .bottomright;
    if (std.mem.eql(u8, pos_str, "center")) return .center;
    return .topright; // default
}

fn parseDigitSize(size_str: []const u8) widgets.digits.Size {
    if (std.mem.eql(u8, size_str, "small")) return .small;
    if (std.mem.eql(u8, size_str, "medium")) return .medium;
    if (std.mem.eql(u8, size_str, "large")) return .large;
    return .small; // default
}

