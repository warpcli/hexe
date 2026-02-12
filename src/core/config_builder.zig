const std = @import("std");
const config = @import("config.zig");

/// ConfigBuilder accumulates configuration from Lua API calls
/// and builds the final Config structs for all sections (mux, ses, shp, pop)
pub const ConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Section builders
    mux: ?*MuxConfigBuilder = null,
    ses: ?*SesConfigBuilder = null,
    shp: ?*ShpConfigBuilder = null,
    pop: ?*PopConfigBuilder = null,

    pub fn init(allocator: std.mem.Allocator) !ConfigBuilder {
        return ConfigBuilder{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConfigBuilder) void {
        if (self.mux) |mux| {
            mux.deinit();
            self.allocator.destroy(mux);
        }
        if (self.ses) |ses| {
            ses.deinit();
            self.allocator.destroy(ses);
        }
        if (self.shp) |shp| {
            shp.deinit();
            self.allocator.destroy(shp);
        }
        if (self.pop) |pop| {
            pop.deinit();
            self.allocator.destroy(pop);
        }
    }

    /// Build final Config from accumulated state
    pub fn build(self: *ConfigBuilder) !config.Config {
        var result = config.Config{};
        result._allocator = self.allocator;

        // TODO: Build config from section builders

        return result;
    }
};

/// MUX section builder - accumulates mux configuration
pub const MuxConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Options
    confirm_on_exit: ?bool = null,
    confirm_on_detach: ?bool = null,
    confirm_on_disown: ?bool = null,
    confirm_on_close: ?bool = null,
    winpulse_enabled: ?bool = null,
    winpulse_duration_ms: ?u32 = null,
    winpulse_brighten_factor: ?f32 = null,
    selection_color: ?u8 = null,
    mouse_selection_override_mods: ?u8 = null,

    // Keybindings
    binds: std.ArrayList(config.Config.Bind),

    // Floats
    float_defaults: ?FloatDefaults = null,
    floats: std.ArrayList(config.FloatDef),

    // Tabs
    tabs_config: TabsConfig,

    // Splits
    splits_config: SplitsConfig,

    const FloatDefaults = struct {
        width_percent: ?u8 = null,
        height_percent: ?u8 = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        color: ?config.BorderColor = null,
        style: ?config.FloatStyle = null,
        attributes: ?config.FloatAttributes = null,
    };

    const TabsConfig = struct {
        status_enabled: ?bool = null,
        segments_left: std.ArrayList(config.Segment),
        segments_center: std.ArrayList(config.Segment),
        segments_right: std.ArrayList(config.Segment),
    };

    const SplitsConfig = struct {
        color: ?config.BorderColor = null,
        separator_v: ?u21 = null,
        separator_h: ?u21 = null,
        style: ?config.SplitStyle = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*MuxConfigBuilder {
        const self = try allocator.create(MuxConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .binds = .{},
            .floats = .{},
            .tabs_config = .{
                .segments_left = .{},
                .segments_center = .{},
                .segments_right = .{},
            },
            .splits_config = .{},
        };
        return self;
    }

    pub fn deinit(self: *MuxConfigBuilder) void {
        self.binds.deinit(self.allocator);
        self.floats.deinit(self.allocator);
        self.tabs_config.segments_left.deinit(self.allocator);
        self.tabs_config.segments_center.deinit(self.allocator);
        self.tabs_config.segments_right.deinit(self.allocator);
    }

    pub fn build(self: *MuxConfigBuilder) !config.Config {
        var result = config.Config{};
        result._allocator = self.allocator;

        // Apply options
        if (self.confirm_on_exit) |v| result.confirm_on_exit = v;
        if (self.confirm_on_detach) |v| result.confirm_on_detach = v;
        if (self.confirm_on_disown) |v| result.confirm_on_disown = v;
        if (self.confirm_on_close) |v| result.confirm_on_close = v;
        if (self.winpulse_enabled) |v| result.winpulse_enabled = v;
        if (self.winpulse_duration_ms) |v| result.winpulse_duration_ms = v;
        if (self.winpulse_brighten_factor) |v| result.winpulse_brighten_factor = v;
        if (self.selection_color) |v| result.selection_color = v;
        if (self.mouse_selection_override_mods) |v| result.mouse.selection_override_mods = v;

        // Apply binds
        if (self.binds.items.len > 0) {
            result.input.binds = try self.binds.toOwnedSlice(self.allocator);
        }

        // Apply float defaults
        if (self.float_defaults) |defaults| {
            if (defaults.width_percent) |v| result.float_width_percent = v;
            if (defaults.height_percent) |v| result.float_height_percent = v;
            if (defaults.padding_x) |v| result.float_padding_x = v;
            if (defaults.padding_y) |v| result.float_padding_y = v;
            if (defaults.color) |v| result.float_color = v;
            if (defaults.style) |v| result.float_style_default = v;
            if (defaults.attributes) |v| result.float_default_attributes = v;
        }

        // Apply tabs config
        if (self.tabs_config.status_enabled) |v| result.tabs.status.enabled = v;
        if (self.tabs_config.segments_left.items.len > 0) {
            result.tabs.status.left = try self.tabs_config.segments_left.toOwnedSlice(self.allocator);
        }
        if (self.tabs_config.segments_center.items.len > 0) {
            result.tabs.status.center = try self.tabs_config.segments_center.toOwnedSlice(self.allocator);
        }
        if (self.tabs_config.segments_right.items.len > 0) {
            result.tabs.status.right = try self.tabs_config.segments_right.toOwnedSlice(self.allocator);
        }

        // Apply splits config
        if (self.splits_config.color) |v| result.splits.color = v;
        if (self.splits_config.separator_v) |v| result.splits.separator_v = v;
        if (self.splits_config.separator_h) |v| result.splits.separator_h = v;
        if (self.splits_config.style) |v| result.splits.style = v;

        return result;
    }
};

/// SES section builder - accumulates session/layout configuration
pub const SesConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Layouts
    layouts: std.ArrayList(config.LayoutDef),

    // Session config (for future use - not in current config.zig)
    auto_restore: ?bool = null,
    save_on_detach: ?bool = null,

    pub fn init(allocator: std.mem.Allocator) !*SesConfigBuilder {
        const self = try allocator.create(SesConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .layouts = .{},
        };
        return self;
    }

    pub fn deinit(self: *SesConfigBuilder) void {
        // Clean up layouts
        for (self.layouts.items) |*layout| {
            var l = @constCast(layout);
            l.deinit(self.allocator);
        }
        self.layouts.deinit(self.allocator);
    }

    pub fn build(self: *SesConfigBuilder) !config.SesConfig {
        var result = config.SesConfig{};

        // Transfer layouts
        if (self.layouts.items.len > 0) {
            result.layouts = try self.layouts.toOwnedSlice(self.allocator);
        }

        return result;
    }
};

/// SHP section builder - accumulates shell prompt configuration
pub const ShpConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Prompt segments
    left_segments: std.ArrayList(SegmentDef),
    right_segments: std.ArrayList(SegmentDef),

    // Temporary struct for prompt segments (similar to config.Segment but for SHP)
    pub const SegmentDef = struct {
        name: []const u8,
        priority: i64,
        outputs: []const OutputDef,
        command: ?[]const u8,
        when: ?config.WhenDef,
    };

    pub const OutputDef = struct {
        style: []const u8,
        format: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) !*ShpConfigBuilder {
        const self = try allocator.create(ShpConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .left_segments = .{},
            .right_segments = .{},
        };
        return self;
    }

    pub fn deinit(self: *ShpConfigBuilder) void {
        // Clean up segments
        for (self.left_segments.items) |seg| {
            self.allocator.free(seg.name);
            if (seg.command) |cmd| self.allocator.free(cmd);
            for (seg.outputs) |out| {
                self.allocator.free(out.style);
                self.allocator.free(out.format);
            }
            self.allocator.free(seg.outputs);
        }
        for (self.right_segments.items) |seg| {
            self.allocator.free(seg.name);
            if (seg.command) |cmd| self.allocator.free(cmd);
            for (seg.outputs) |out| {
                self.allocator.free(out.style);
                self.allocator.free(out.format);
            }
            self.allocator.free(seg.outputs);
        }
        self.left_segments.deinit(self.allocator);
        self.right_segments.deinit(self.allocator);
    }
};

/// POP section builder - accumulates popup/overlay configuration
pub const PopConfigBuilder = struct {
    allocator: std.mem.Allocator,

    // Notification styles (carrier = mux realm, pane = pane realm)
    carrier_notification: ?NotificationStyleDef = null,
    pane_notification: ?NotificationStyleDef = null,

    // Dialog styles
    carrier_confirm: ?ConfirmStyleDef = null,
    pane_confirm: ?ConfirmStyleDef = null,
    carrier_choose: ?ChooseStyleDef = null,
    pane_choose: ?ChooseStyleDef = null,

    // Widgets config
    widgets: WidgetsConfigDef,

    pub const NotificationStyleDef = struct {
        fg: ?u8 = null,
        bg: ?u8 = null,
        bold: ?bool = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        offset: ?u8 = null,
        alignment: ?[]const u8 = null,
        duration_ms: ?u32 = null,
    };

    pub const ConfirmStyleDef = struct {
        fg: ?u8 = null,
        bg: ?u8 = null,
        bold: ?bool = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        yes_label: ?[]const u8 = null,
        no_label: ?[]const u8 = null,
    };

    pub const ChooseStyleDef = struct {
        fg: ?u8 = null,
        bg: ?u8 = null,
        highlight_fg: ?u8 = null,
        highlight_bg: ?u8 = null,
        bold: ?bool = null,
        padding_x: ?u8 = null,
        padding_y: ?u8 = null,
        visible_count: ?u8 = null,
    };

    const WidgetsConfigDef = struct {
        pokemon_enabled: ?bool = null,
        pokemon_position: ?[]const u8 = null,
        pokemon_shiny_chance: ?f32 = null,

        keycast_enabled: ?bool = null,
        keycast_position: ?[]const u8 = null,
        keycast_duration_ms: ?i64 = null,
        keycast_max_entries: ?u8 = null,
        keycast_grouping_timeout_ms: ?i64 = null,

        digits_enabled: ?bool = null,
        digits_position: ?[]const u8 = null,
        digits_size: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) !*PopConfigBuilder {
        const self = try allocator.create(PopConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .widgets = .{},
        };
        return self;
    }

    pub fn deinit(self: *PopConfigBuilder) void {
        // Clean up allocated strings if any
        if (self.carrier_notification) |*notif| {
            if (notif.alignment) |a| self.allocator.free(a);
        }
        if (self.pane_notification) |*notif| {
            if (notif.alignment) |a| self.allocator.free(a);
        }
        if (self.carrier_confirm) |*conf| {
            if (conf.yes_label) |y| self.allocator.free(y);
            if (conf.no_label) |n| self.allocator.free(n);
        }
        if (self.pane_confirm) |*conf| {
            if (conf.yes_label) |y| self.allocator.free(y);
            if (conf.no_label) |n| self.allocator.free(n);
        }
        // Widget strings cleanup
        if (self.widgets.pokemon_position) |p| self.allocator.free(p);
        if (self.widgets.keycast_position) |p| self.allocator.free(p);
        if (self.widgets.digits_position) |p| self.allocator.free(p);
        if (self.widgets.digits_size) |s| self.allocator.free(s);
    }
};
