const std = @import("std");

/// Log levels in order of severity
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn prefix(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Global log configuration
pub var min_level: Level = .warn;
pub var enabled: bool = false;

/// Module-specific debug flags (for backward compatibility)
pub var mux_debug: bool = false;
pub var ses_debug: bool = false;
pub var pod_debug: bool = false;
pub var shp_debug: bool = false;

/// Enable all debug logging
pub fn enableAll() void {
    enabled = true;
    min_level = .debug;
    mux_debug = true;
    ses_debug = true;
    pod_debug = true;
    shp_debug = true;
}

/// Log a message with the given level and module prefix
pub fn log(level: Level, comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;
    std.debug.print("[{s}][{s}] " ++ fmt ++ "\n", .{ level.prefix(), module } ++ args);
}

/// Convenience functions for each level
pub fn debug(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.debug, module, fmt, args);
}

pub fn info(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.info, module, fmt, args);
}

pub fn warn(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.warn, module, fmt, args);
}

pub fn err(comptime module: []const u8, comptime fmt: []const u8, args: anytype) void {
    log(.err, module, fmt, args);
}

/// Log an error with context (useful for replacing silent catch {})
pub fn logError(comptime module: []const u8, comptime context: []const u8, error_val: anyerror) void {
    if (!enabled) return;
    std.debug.print("[ERROR][{s}] {s}: {s}\n", .{ module, context, @errorName(error_val) });
}

/// Helper for common pattern: log error and return
pub fn catchLog(comptime module: []const u8, comptime context: []const u8) fn (anyerror) void {
    return struct {
        fn handler(error_val: anyerror) void {
            logError(module, context, error_val);
        }
    }.handler;
}
