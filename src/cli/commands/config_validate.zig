const std = @import("std");
const core = @import("core");

const print = std.debug.print;

/// Validate the Hexa configuration file
pub fn run() !void {
    const allocator = std.heap.page_allocator;

    // Get config path
    const home = std.posix.getenv("HOME") orelse {
        print("Error: HOME environment variable not set\n", .{});
        return error.NoHome;
    };

    const config_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.config/hexe/mux.lua",
        .{home},
    );
    defer allocator.free(config_path);

    // Check if config file exists
    std.fs.accessAbsolute(config_path, .{}) catch {
        print("✓ No config file found (using defaults)\n", .{});
        print("  Expected location: {s}\n", .{config_path});
        return;
    };

    // Try to load the config
    var runtime = core.LuaRuntime.init(allocator) catch {
        print("✗ Failed to initialize Lua runtime\n", .{});
        return error.LuaInitFailed;
    };
    defer runtime.deinit();

    // Load config file
    const config_z = allocator.dupeZ(u8, config_path) catch {
        print("✗ Memory allocation failed\n", .{});
        return error.OutOfMemory;
    };
    defer allocator.free(config_z);

    runtime.lua.doFile(config_z) catch |err| {
        print("✗ Config validation failed: {s}\n", .{config_path});
        print("\nSyntax error in Lua config file.\n", .{});
        print("Check for:\n", .{});
        print("  - Missing commas between table entries\n", .{});
        print("  - Unclosed brackets or braces\n", .{});
        print("  - Invalid Lua syntax\n", .{});
        print("  - Typos in configuration keys\n", .{});
        print("\nRun with 'hexe mux' to see more detailed error messages.\n", .{});
        return err;
    };

    // Parse the config table
    const config = core.config.Config.parseFromLua(&runtime, false) catch |err| {
        print("✗ Config validation failed: {s}\n", .{config_path});
        print("\nConfiguration structure error.\n", .{});
        print("Common issues:\n", .{});
        print("  - Invalid color format (use hex like '#rrggbb')\n", .{});
        print("  - Invalid keybinding syntax\n", .{});
        print("  - Missing required fields\n", .{});
        print("  - Type mismatches (string vs number)\n", .{});
        print("\nRun with 'hexe mux' to see the actual config being used.\n", .{});
        return err;
    };
    defer config.deinit(allocator);

    // Success!
    print("✓ Config valid: {s}\n", .{config_path});
    print("\nConfiguration loaded successfully:\n", .{});

    // Show some config highlights
    print("  - Tabs enabled: {}\n", .{config.tabs.enabled});
    print("  - Status bar enabled: {}\n", .{config.tabs.status.enabled});
    print("  - Keybindings: {} defined\n", .{config.keybindings.len});

    if (config.status_segments) |segments| {
        print("  - Status segments: {} defined\n", .{segments.len});
    }

    print("\n✓ All checks passed\n", .{});
}
