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

/// Placeholder for MUX section builder
pub const MuxConfigBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*MuxConfigBuilder {
        const self = try allocator.create(MuxConfigBuilder);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *MuxConfigBuilder) void {
        _ = self;
    }
};

/// Placeholder for SES section builder
pub const SesConfigBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*SesConfigBuilder {
        const self = try allocator.create(SesConfigBuilder);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn deinit(self: *SesConfigBuilder) void {
        _ = self;
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
