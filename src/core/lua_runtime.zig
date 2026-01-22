const std = @import("std");
const posix = std.posix;
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaState = zlua.LuaState;
const LuaType = zlua.LuaType;

/// Configuration loading status
pub const ConfigStatus = enum {
    loaded,
    missing,
    @"error",
};

/// Result of loading a config file
pub const ConfigResult = struct {
    status: ConfigStatus,
    message: ?[]const u8 = null,
};

/// Check if unsafe config mode is enabled
pub fn isUnsafeMode() bool {
    if (posix.getenv("HEXE_UNSAFE_CONFIG")) |v| {
        return std.mem.eql(u8, v, "1");
    }
    return false;
}

/// Get the config directory path
pub fn getConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    if (posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/hexe", .{xdg});
    }
    const home = posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/hexe", .{home});
}

/// Get the path to a specific config file
pub fn getConfigPath(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const dir = try getConfigDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
}

/// Lua runtime for config loading
pub const LuaRuntime = struct {
    lua: *Lua,
    allocator: std.mem.Allocator,
    unsafe_mode: bool,
    last_error: ?[]const u8 = null,

    const Self = @This();

    /// Create a new Lua runtime
    pub fn init(allocator: std.mem.Allocator) !Self {
        const unsafe = isUnsafeMode();
        var lua = try Lua.init(allocator);

        // Open safe standard libraries
        lua.openBase();
        lua.openTable();
        lua.openString();
        lua.openMath();
        lua.openUtf8();

        // Unsafe mode: open additional libraries
        if (unsafe) {
            lua.openIO();
            lua.openOS();
            lua.openPackage();
        }

        // Set up require
        if (unsafe) {
            try setupUnsafeRequire(lua, allocator);
        } else {
            try setupSafeRequire(lua);
        }

        // Inject hexe module
        try injectHexeModule(lua);

        return .{
            .lua = lua,
            .allocator = allocator,
            .unsafe_mode = unsafe,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        self.lua.deinit();
    }

    /// Load a Lua config file and return the top-level table
    /// Returns the index of the table on the stack (always 1 after successful load)
    pub fn loadConfig(self: *Self, path: []const u8) !void {
        // Clear any previous error
        if (self.last_error) |err| {
            self.allocator.free(err);
            self.last_error = null;
        }

        // Path needs to be null-terminated for loadFile
        const path_z = self.allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer self.allocator.free(path_z);

        // Load and execute the file
        self.lua.loadFile(path_z, .binary_text) catch |err| {
            if (err == error.LuaFile) {
                return error.FileNotFound;
            }
            self.last_error = try self.allocator.dupe(u8, self.getErrorMessage());
            return error.LuaError;
        };

        // Execute the loaded chunk
        self.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
            self.last_error = try self.allocator.dupe(u8, self.getErrorMessage());
            return error.LuaError;
        };

        // Check that the result is a table
        if (self.lua.typeOf(-1) != .table) {
            self.last_error = try self.allocator.dupe(u8, "config must return a table");
            self.lua.pop(1);
            return error.InvalidReturn;
        }
    }

    fn getErrorMessage(self: *Self) []const u8 {
        if (self.lua.typeOf(-1) == .string) {
            return self.lua.toString(-1) catch "unknown error";
        }
        return "unknown error";
    }

    // ===== Table reading helpers =====

    /// Get a string field from the table at the given index
    pub fn getString(self: *Self, table_idx: i32, key: [:0]const u8) ?[]const u8 {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .string) {
            return self.lua.toString(-1) catch null;
        }
        return null;
    }

    /// Get an allocated copy of a string field
    pub fn getStringAlloc(self: *Self, table_idx: i32, key: [:0]const u8) ?[]const u8 {
        if (self.getString(table_idx, key)) |s| {
            return self.allocator.dupe(u8, s) catch null;
        }
        return null;
    }

    /// Get an integer field from the table
    pub fn getInt(self: *Self, comptime T: type, table_idx: i32, key: [:0]const u8) ?T {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .number) {
            const val = self.lua.toInteger(-1) catch return null;
            return std.math.cast(T, val);
        }
        return null;
    }

    /// Get a number field from the table
    pub fn getNumber(self: *Self, table_idx: i32, key: [:0]const u8) ?f64 {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .number) {
            return self.lua.toNumber(-1) catch null;
        }
        return null;
    }

    /// Get a boolean field from the table
    pub fn getBool(self: *Self, table_idx: i32, key: [:0]const u8) ?bool {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        if (self.lua.typeOf(-1) == .boolean) {
            return self.lua.toBoolean(-1);
        }
        return null;
    }

    /// Check if a field exists and is a table
    pub fn hasTable(self: *Self, table_idx: i32, key: [:0]const u8) bool {
        _ = self.lua.getField(table_idx, key);
        defer self.lua.pop(1);
        return self.lua.typeOf(-1) == .table;
    }

    /// Push a table field onto the stack (caller must pop when done)
    pub fn pushTable(self: *Self, table_idx: i32, key: [:0]const u8) bool {
        _ = self.lua.getField(table_idx, key);
        if (self.lua.typeOf(-1) == .table) {
            return true;
        }
        self.lua.pop(1);
        return false;
    }

    /// Get the length of an array table at the given stack index
    pub fn getArrayLen(self: *Self, table_idx: i32) usize {
        return @intCast(self.lua.rawLen(table_idx));
    }

    /// Push array element at 1-based index onto stack (caller must pop)
    pub fn pushArrayElement(self: *Self, table_idx: i32, index: usize) bool {
        _ = self.lua.rawGetIndex(table_idx, @intCast(index));
        if (self.lua.typeOf(-1) != .nil) {
            return true;
        }
        self.lua.pop(1);
        return false;
    }

    /// Pop the top element from the stack
    pub fn pop(self: *Self) void {
        self.lua.pop(1);
    }

    /// Get the type at stack index
    pub fn typeOf(self: *Self, idx: i32) LuaType {
        return self.lua.typeOf(idx);
    }

    /// Convert stack top to string
    pub fn toStringAt(self: *Self, idx: i32) ?[]const u8 {
        return self.lua.toString(idx) catch null;
    }

    /// Convert stack top to integer
    pub fn toIntAt(self: *Self, comptime T: type, idx: i32) ?T {
        const val = self.lua.toInteger(idx) catch return null;
        return std.math.cast(T, val);
    }
};

// ===== Internal setup functions =====

fn setupSafeRequire(lua: *Lua) !void {
    // In safe mode, only allow require("hexe")
    lua.pushFunction(safeRequire);
    lua.setGlobal("require");
}

fn safeRequire(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    const name = lua.toString(1) catch {
        _ = lua.pushString("require: expected string argument");
        lua.raiseError();
    };

    if (std.mem.eql(u8, name, "hexe")) {
        // Return the hexe module from registry
        _ = lua.getField(zlua.registry_index, "_hexe_module");
        return 1;
    }

    _ = lua.pushString("require() not allowed in safe mode");
    lua.raiseError();
}

fn setupUnsafeRequire(lua: *Lua, allocator: std.mem.Allocator) !void {
    // Set up restricted package.path (only hexe config dirs)
    const config_dir = getConfigDir(allocator) catch return;
    defer allocator.free(config_dir);

    const path = std.fmt.allocPrint(allocator, "{s}/lua/?.lua;{s}/lua/?/init.lua", .{ config_dir, config_dir }) catch return;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    // Set package.path
    _ = lua.getGlobal("package") catch return;
    if (lua.typeOf(-1) == .table) {
        _ = lua.pushString(path_z);
        lua.setField(-2, "path");
        // Clear cpath to disable native modules
        _ = lua.pushString("");
        lua.setField(-2, "cpath");
    }
    lua.pop(1);

    // Preload hexe module
    _ = lua.getGlobal("package") catch return;
    if (lua.typeOf(-1) == .table) {
        _ = lua.getField(-1, "preload");
        if (lua.typeOf(-1) == .table) {
            lua.pushFunction(hexeLoader);
            lua.setField(-2, "hexe");
        }
        lua.pop(1); // preload
    }
    lua.pop(1); // package
}

fn injectHexeModule(lua: *Lua) !void {
    // Create the hexe module table
    lua.createTable(0, 5);

    // hx.mod = { ctrl = 2, alt = 1, shift = 4, super = 8 }
    lua.createTable(0, 4);
    lua.pushInteger(2);
    lua.setField(-2, "ctrl");
    lua.pushInteger(1);
    lua.setField(-2, "alt");
    lua.pushInteger(4);
    lua.setField(-2, "shift");
    lua.pushInteger(8);
    lua.setField(-2, "super");
    lua.setField(-2, "mod");

    // hx.when = { press = "press", release = "release", repeat = "repeat", hold = "hold", double_tap = "double_tap" }
    lua.createTable(0, 5);
    _ = lua.pushString("press");
    lua.setField(-2, "press");
    _ = lua.pushString("release");
    lua.setField(-2, "release");
    _ = lua.pushString("repeat");
    lua.setField(-2, "repeat");
    _ = lua.pushString("hold");
    lua.setField(-2, "hold");
    _ = lua.pushString("double_tap");
    lua.setField(-2, "double_tap");
    lua.setField(-2, "when");

    // hx.action = { mux_quit = "mux.quit", tab_new = "tab.new", ... }
    lua.createTable(0, 14);
    _ = lua.pushString("mux.quit");
    lua.setField(-2, "mux_quit");
    _ = lua.pushString("mux.detach");
    lua.setField(-2, "mux_detach");
    _ = lua.pushString("pane.disown");
    lua.setField(-2, "pane_disown");
    _ = lua.pushString("pane.adopt");
    lua.setField(-2, "pane_adopt");
    _ = lua.pushString("split.h");
    lua.setField(-2, "split_h");
    _ = lua.pushString("split.v");
    lua.setField(-2, "split_v");
    _ = lua.pushString("split.resize");
    lua.setField(-2, "split_resize");
    _ = lua.pushString("tab.new");
    lua.setField(-2, "tab_new");
    _ = lua.pushString("tab.next");
    lua.setField(-2, "tab_next");
    _ = lua.pushString("tab.prev");
    lua.setField(-2, "tab_prev");
    _ = lua.pushString("tab.close");
    lua.setField(-2, "tab_close");
    _ = lua.pushString("float.toggle");
    lua.setField(-2, "float_toggle");
    _ = lua.pushString("float.nudge");
    lua.setField(-2, "float_nudge");
    _ = lua.pushString("focus.move");
    lua.setField(-2, "focus_move");
    lua.setField(-2, "action");

    // hx.version
    _ = lua.pushString("0.1.0");
    lua.setField(-2, "version");

    // Store in registry for safe require
    lua.pushValue(-1); // duplicate
    lua.setField(zlua.registry_index, "_hexe_module");
}

fn hexeLoader(state: ?*LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state orelse return 0);
    // Return the hexe module from registry
    _ = lua.getField(zlua.registry_index, "_hexe_module");
    return 1;
}

// ===== Parsing helpers for configs =====

/// Parse a Unicode character from a Lua string field
pub fn parseUnicodeChar(runtime: *LuaRuntime, table_idx: i32, key: [:0]const u8, default: u21) u21 {
    const str = runtime.getString(table_idx, key) orelse return default;
    if (str.len == 0) return default;
    return std.unicode.utf8Decode(str) catch default;
}

/// Parse a constrained integer (with min/max bounds)
pub fn parseConstrainedInt(runtime: *LuaRuntime, comptime T: type, table_idx: i32, key: [:0]const u8, min: T, max: T, default: T) T {
    const val = runtime.getInt(i64, table_idx, key) orelse return default;
    if (val < min) return min;
    if (val > max) return max;
    return @intCast(val);
}
