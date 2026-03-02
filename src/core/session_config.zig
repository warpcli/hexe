const std = @import("std");
const posix = std.posix;
const lua_runtime = @import("lua_runtime.zig");
const LuaRuntime = lua_runtime.LuaRuntime;

/// Direction of a split in session config.
pub const SplitDir = enum {
    horizontal,
    vertical,
};

/// A leaf pane in the split tree.
pub const PaneConfig = struct {
    cmd: ?[]const u8 = null,
    cwd: ?[]const u8 = null, // relative to root, resolved at apply time
};

/// A node in the split tree: either a single pane or a split.
pub const SplitConfig = union(enum) {
    pane: PaneConfig,
    split: SplitNode,

    pub const SplitNode = struct {
        dir: SplitDir,
        children: []SplitChild,
    };
};

/// A child in an N-ary split, with an optional size percentage.
pub const SplitChild = struct {
    size: ?u8 = null, // percentage, null = equal
    node: SplitConfig,
};

/// A float pane definition.
pub const FloatConfig = struct {
    key: u8 = 0,
    cmd: ?[]const u8 = null,
    width: u8 = 80,
    height: u8 = 80,
    pos_x: u8 = 50,
    pos_y: u8 = 50,
    title: ?[]const u8 = null,
    global: bool = false,
};

/// A tab definition.
pub const TabConfig = struct {
    name: []const u8,
    split: ?SplitConfig = null, // null = single pane with default shell
    floats: []FloatConfig = &.{},
};

/// Top-level session configuration parsed from .hexe.lua.
pub const SessionConfig = struct {
    name: ?[]const u8 = null,
    root: ?[]const u8 = null,
    on_start: [][]const u8 = &.{},
    on_stop: [][]const u8 = &.{},
    tabs: []TabConfig = &.{},
    floats: []FloatConfig = &.{}, // global floats
    filter_tab: ?[]const u8 = null, // if set, only launch this tab
};

/// Get the sessions directory (~/.local/share/hexe/sessions/).
pub fn getSessionsDir(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_DATA_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe/sessions", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/hexe/sessions", .{home});
}

/// Resolve a CLI argument to a .hexe.lua config path.
///
/// - If arg is a directory (or "."), look for .hexe.lua inside it.
/// - If arg contains ":" suffix, split into name:tab_filter.
/// - If arg is a bare name, look in ~/.local/share/hexe/sessions/<name>.lua.
/// - If arg is a file path, use it directly.
///
/// Returns struct with path and optional tab filter.
pub const ResolvedConfig = struct {
    path: []const u8,
    tab_filter: ?[]const u8 = null,
};

pub fn resolveConfigPath(allocator: std.mem.Allocator, arg: []const u8) !?ResolvedConfig {
    // Split on ":" for tab filter (e.g., "myproject:server")
    var target = arg;
    var tab_filter: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, arg, ':')) |colon_pos| {
        target = arg[0..colon_pos];
        if (colon_pos + 1 < arg.len) {
            tab_filter = try allocator.dupe(u8, arg[colon_pos + 1 ..]);
        }
    }
    errdefer if (tab_filter) |tf| allocator.free(tf);

    // Check if target is "."
    if (std.mem.eql(u8, target, ".")) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch return null;
        const path = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{cwd});
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    }

    // Try opening as a directory
    if (std.fs.cwd().openDir(target, .{})) |*dir_handle| {
        var dir = dir_handle.*;
        defer dir.close();
        const abs_target = dir.realpathAlloc(allocator, ".") catch return null;
        defer allocator.free(abs_target);
        const path = try std.fmt.allocPrint(allocator, "{s}/.hexe.lua", .{abs_target});
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    } else |_| {}

    // If target is a file path ending in .lua, use directly
    if (std.mem.endsWith(u8, target, ".lua")) {
        const path = try allocator.dupe(u8, target);
        std.fs.cwd().access(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        return .{ .path = path, .tab_filter = tab_filter };
    }

    // Treat as session name, look in sessions dir
    const sessions_dir = getSessionsDir(allocator) catch return null;
    defer allocator.free(sessions_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.lua", .{ sessions_dir, target });
    std.fs.cwd().access(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return .{ .path = path, .tab_filter = tab_filter };
}

/// Parse a .hexe.lua file into a SessionConfig.
pub fn parseSessionLua(allocator: std.mem.Allocator, path: []const u8) !SessionConfig {
    var runtime = try LuaRuntime.init(allocator);
    defer runtime.deinit();

    runtime.loadConfig(path) catch |err| {
        if (err == error.FileNotFound) return err;
        if (runtime.last_error) |msg| {
            std.debug.print("Error loading {s}: {s}\n", .{ path, msg });
        }
        return error.LuaError;
    };

    // The file should return a table — check top of stack
    if (runtime.typeOf(-1) != .table) {
        std.debug.print("Error: {s} must return a table\n", .{path});
        return error.LuaError;
    }

    var config = SessionConfig{};

    // Read top-level fields
    if (runtime.getStringAlloc(-1, "name")) |s| config.name = s;
    if (runtime.getStringAlloc(-1, "root")) |s| config.root = s;

    // Read on_start
    config.on_start = parseStringArray(allocator, &runtime, -1, "on_start") catch &.{};

    // Read on_stop
    config.on_stop = parseStringArray(allocator, &runtime, -1, "on_stop") catch &.{};

    // Read tabs
    config.tabs = parseTabs(allocator, &runtime, -1) catch &.{};

    // Read global floats
    config.floats = parseFloats(allocator, &runtime, -1) catch &.{};

    return config;
}

fn parseStringArray(allocator: std.mem.Allocator, runtime: *LuaRuntime, table_idx: i32, key: [:0]const u8) ![][]const u8 {
    if (!runtime.pushTable(table_idx, key)) return &.{};
    defer runtime.pop();

    const len = runtime.getArrayLen(-1);
    if (len == 0) return &.{};

    var list = try std.ArrayList([]const u8).initCapacity(allocator, len);
    errdefer list.deinit(allocator);

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        if (runtime.pushArrayElement(-1, i)) {
            defer runtime.pop();
            if (runtime.toStringAt(-1)) |s| {
                const duped = try allocator.dupe(u8, s);
                try list.append(allocator, duped);
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseTabs(allocator: std.mem.Allocator, runtime: *LuaRuntime, table_idx: i32) ![]TabConfig {
    if (!runtime.pushTable(table_idx, "tabs")) return &.{};
    defer runtime.pop();

    const len = runtime.getArrayLen(-1);
    if (len == 0) return &.{};

    var list = try std.ArrayList(TabConfig).initCapacity(allocator, len);
    errdefer list.deinit(allocator);

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        if (runtime.pushArrayElement(-1, i)) {
            defer runtime.pop();

            const name = runtime.getStringAlloc(-1, "name") orelse
                try std.fmt.allocPrint(allocator, "tab-{d}", .{i});

            var tab = TabConfig{
                .name = name,
            };

            // Parse split tree
            if (runtime.pushTable(-1, "split")) {
                defer runtime.pop();
                tab.split = parseSplitConfig(allocator, runtime) catch null;
            }

            // Parse per-tab floats
            tab.floats = parseFloats(allocator, runtime, -1) catch &.{};

            try list.append(allocator, tab);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseSplitConfig(allocator: std.mem.Allocator, runtime: *LuaRuntime) !SplitConfig {
    // Check if this is a split node (has "dir" field) or a leaf (has "cmd" or is simple)
    if (runtime.getString(-1, "dir")) |dir_str| {
        // It's a split node
        const dir: SplitDir = if (std.mem.eql(u8, dir_str, "vertical")) .vertical else .horizontal;

        // Read array children (1-based numeric keys)
        const len = runtime.getArrayLen(-1);
        if (len == 0) return error.InvalidConfig;

        var children = try std.ArrayList(SplitChild).initCapacity(allocator, len);
        errdefer children.deinit(allocator);

        var i: usize = 1;
        while (i <= len) : (i += 1) {
            if (runtime.pushArrayElement(-1, i)) {
                defer runtime.pop();

                const size = runtime.getInt(u8, -1, "size");

                // Check if child is a split node or a leaf
                const node = if (runtime.getString(-1, "dir") != null)
                    try parseSplitConfig(allocator, runtime)
                else blk: {
                    const cmd = runtime.getStringAlloc(-1, "cmd");
                    const cwd = runtime.getStringAlloc(-1, "cwd");
                    break :blk SplitConfig{ .pane = .{ .cmd = cmd, .cwd = cwd } };
                };

                try children.append(allocator, .{
                    .size = size,
                    .node = node,
                });
            }
        }

        return SplitConfig{
            .split = .{
                .dir = dir,
                .children = try children.toOwnedSlice(allocator),
            },
        };
    } else {
        // It's a leaf pane
        const cmd = runtime.getStringAlloc(-1, "cmd");
        const cwd = runtime.getStringAlloc(-1, "cwd");
        return SplitConfig{ .pane = .{ .cmd = cmd, .cwd = cwd } };
    }
}

fn parseFloats(allocator: std.mem.Allocator, runtime: *LuaRuntime, table_idx: i32) ![]FloatConfig {
    if (!runtime.pushTable(table_idx, "floats")) return &.{};
    defer runtime.pop();

    const len = runtime.getArrayLen(-1);
    if (len == 0) return &.{};

    var list = try std.ArrayList(FloatConfig).initCapacity(allocator, len);
    errdefer list.deinit(allocator);

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        if (runtime.pushArrayElement(-1, i)) {
            defer runtime.pop();

            var float = FloatConfig{};

            // key: single character
            if (runtime.getString(-1, "key")) |key_str| {
                if (key_str.len > 0) float.key = key_str[0];
            }

            float.cmd = runtime.getStringAlloc(-1, "cmd");
            float.width = runtime.getInt(u8, -1, "width") orelse 80;
            float.height = runtime.getInt(u8, -1, "height") orelse 80;
            float.pos_x = runtime.getInt(u8, -1, "pos_x") orelse 50;
            float.pos_y = runtime.getInt(u8, -1, "pos_y") orelse 50;
            float.title = runtime.getStringAlloc(-1, "title");
            float.global = runtime.getBool(-1, "global") orelse false;

            try list.append(allocator, float);
        }
    }

    return list.toOwnedSlice(allocator);
}
