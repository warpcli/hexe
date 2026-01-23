const std = @import("std");
const core = @import("core");
const lua_runtime = core.lua_runtime;
const LuaRuntime = core.LuaRuntime;
const ConfigStatus = core.ConfigStatus;

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
    status: ConfigStatus = .loaded,
    status_message: ?[]const u8 = null,

    _allocator: ?std.mem.Allocator = null,

    pub fn load(allocator: std.mem.Allocator) PopConfig {
        var config = PopConfig{};
        config._allocator = allocator;

        const path = lua_runtime.getConfigPath(allocator, "config.lua") catch return config;
        defer allocator.free(path);

        var runtime = LuaRuntime.init(allocator) catch {
            config.status = .@"error";
            config.status_message = allocator.dupe(u8, "failed to initialize Lua") catch null;
            return config;
        };
        defer runtime.deinit();

        // Let a single config.lua avoid building other sections.
        runtime.setHexeSection("pop");

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

        // Access the "pop" section of the config table
        if (runtime.pushTable(-1, "pop")) {
            parsePopConfig(&runtime, &config, allocator);
            runtime.pop();
        }

        return config;
    }

    pub fn deinit(self: *PopConfig) void {
        // Free any allocated strings if we had an allocator
        _ = self;
    }
};

fn parsePopConfig(runtime: *LuaRuntime, config: *PopConfig, allocator: std.mem.Allocator) void {
    // Parse carrier section
    if (runtime.pushTable(-1, "carrier")) {
        parseCarrierConfig(runtime, &config.carrier, allocator);
        runtime.pop();
    }

    // Parse pane section
    if (runtime.pushTable(-1, "pane")) {
        parsePaneConfig(runtime, &config.pane, allocator);
        runtime.pop();
    }
}

fn parseCarrierConfig(runtime: *LuaRuntime, carrier: *CarrierConfig, allocator: std.mem.Allocator) void {
    if (runtime.pushTable(-1, "notification")) {
        parseNotificationStyle(runtime, &carrier.notification, allocator);
        runtime.pop();
    }
    if (runtime.pushTable(-1, "confirm")) {
        parseConfirmStyle(runtime, &carrier.confirm, allocator);
        runtime.pop();
    }
    if (runtime.pushTable(-1, "choose")) {
        parseChooseStyle(runtime, &carrier.choose);
        runtime.pop();
    }
}

fn parsePaneConfig(runtime: *LuaRuntime, pane: *PaneConfig, allocator: std.mem.Allocator) void {
    if (runtime.pushTable(-1, "notification")) {
        parseNotificationStyle(runtime, &pane.notification, allocator);
        runtime.pop();
    }
    if (runtime.pushTable(-1, "confirm")) {
        parseConfirmStyle(runtime, &pane.confirm, allocator);
        runtime.pop();
    }
    if (runtime.pushTable(-1, "choose")) {
        parseChooseStyle(runtime, &pane.choose);
        runtime.pop();
    }
}

fn parseNotificationStyle(runtime: *LuaRuntime, style: *NotificationStyle, allocator: std.mem.Allocator) void {
    style.fg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "fg", 0, 255, style.fg);
    style.bg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "bg", 0, 255, style.bg);
    if (runtime.getBool(-1, "bold")) |v| style.bold = v;
    style.padding_x = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_x", 0, 10, style.padding_x);
    style.padding_y = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_y", 0, 10, style.padding_y);
    style.offset = lua_runtime.parseConstrainedInt(runtime, u8, -1, "offset", 0, 20, style.offset);
    if (runtime.getStringAlloc(-1, "alignment")) |v| style.alignment = v else _ = allocator;
    style.duration_ms = lua_runtime.parseConstrainedInt(runtime, u32, -1, "duration_ms", 100, 60000, style.duration_ms);
}

fn parseConfirmStyle(runtime: *LuaRuntime, style: *ConfirmStyle, allocator: std.mem.Allocator) void {
    style.fg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "fg", 0, 255, style.fg);
    style.bg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "bg", 0, 255, style.bg);
    if (runtime.getBool(-1, "bold")) |v| style.bold = v;
    style.padding_x = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_x", 0, 10, style.padding_x);
    style.padding_y = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_y", 0, 10, style.padding_y);
    if (runtime.getStringAlloc(-1, "yes_label")) |v| style.yes_label = v;
    if (runtime.getStringAlloc(-1, "no_label")) |v| style.no_label = v;
    _ = allocator;
}

fn parseChooseStyle(runtime: *LuaRuntime, style: *ChooseStyle) void {
    style.fg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "fg", 0, 255, style.fg);
    style.bg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "bg", 0, 255, style.bg);
    style.highlight_fg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "highlight_fg", 0, 255, style.highlight_fg);
    style.highlight_bg = lua_runtime.parseConstrainedInt(runtime, u8, -1, "highlight_bg", 0, 255, style.highlight_bg);
    if (runtime.getBool(-1, "bold")) |v| style.bold = v;
    style.padding_x = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_x", 0, 10, style.padding_x);
    style.padding_y = lua_runtime.parseConstrainedInt(runtime, u8, -1, "padding_y", 0, 10, style.padding_y);
    style.visible_count = lua_runtime.parseConstrainedInt(runtime, u8, -1, "visible_count", 1, 50, style.visible_count);
}
