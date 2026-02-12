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
            .binds = std.ArrayList(config.Config.Bind).init(allocator),
            .floats = std.ArrayList(config.FloatDef).init(allocator),
            .tabs_config = .{
                .segments_left = std.ArrayList(config.Segment).init(allocator),
                .segments_center = std.ArrayList(config.Segment).init(allocator),
                .segments_right = std.ArrayList(config.Segment).init(allocator),
            },
            .splits_config = .{},
        };
        return self;
    }

    pub fn deinit(self: *MuxConfigBuilder) void {
        self.binds.deinit();
        self.floats.deinit();
        self.tabs_config.segments_left.deinit();
        self.tabs_config.segments_center.deinit();
        self.tabs_config.segments_right.deinit();
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
            result.input.binds = try self.binds.toOwnedSlice();
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
            result.tabs.status.left = try self.tabs_config.segments_left.toOwnedSlice();
        }
        if (self.tabs_config.segments_center.items.len > 0) {
            result.tabs.status.center = try self.tabs_config.segments_center.toOwnedSlice();
        }
        if (self.tabs_config.segments_right.items.len > 0) {
            result.tabs.status.right = try self.tabs_config.segments_right.toOwnedSlice();
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

    pub fn init(allocator: std.mem.Allocator) !*SesConfigBuilder {
        const self = try allocator.create(SesConfigBuilder);
        self.* = .{
            .allocator = allocator,
            .layouts = std.ArrayList(config.LayoutDef).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *SesConfigBuilder) void {
        // Clean up layouts
        for (self.layouts.items) |*layout| {
            var l = @constCast(layout);
            l.deinit(self.allocator);
        }
        self.layouts.deinit();
    }

    pub fn build(self: *SesConfigBuilder) !config.SesConfig {
        var result = config.SesConfig{};

        // Transfer layouts
        if (self.layouts.items.len > 0) {
            result.layouts = try self.layouts.toOwnedSlice();
        }

        return result;
    }
};

/// Placeholder for SHP section builder
pub const ShpConfigBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*ShpConfigBuilder {
        const self = try allocator.create(ShpConfigBuilder);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *ShpConfigBuilder) void {
        _ = self;
    }
};

/// Placeholder for POP section builder
pub const PopConfigBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*PopConfigBuilder {
        const self = try allocator.create(PopConfigBuilder);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *PopConfigBuilder) void {
        _ = self;
    }
};
