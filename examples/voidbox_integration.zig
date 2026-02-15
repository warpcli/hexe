const std = @import("std");
const voidbox = @import("voidbox");

/// Example: Launch isolated shell with voidbox
pub fn launchIsolatedShell(allocator: std.mem.Allocator) !void {
    const config = voidbox.JailConfig{
        .name = "isolated-shell",
        .rootfs_path = "/",
        .cmd = &[_][]const u8{ "/bin/bash", "--norc" },

        .isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        },

        .resources = .{
            .mem = "512M",
            .pids = "100",
            .cpu = null,
        },

        .security = .{
            .no_new_privs = true,
            .cap_drop = "",
            .cap_add = "",
        },
    };

    // Validate configuration
    try voidbox.validate(&config, allocator);

    // Spawn jail
    const session = try voidbox.spawn(&config, allocator);
    defer voidbox.cleanup_session(&session, allocator);

    std.debug.print("Spawned jail session with PID: {}\n", .{session.pid});

    // Wait for completion
    const outcome = try voidbox.wait(&session, allocator);
    std.debug.print("Shell exited with code: {}\n", .{outcome.exit_code});
}

/// Example: Run command in fully isolated jail
pub fn runFullyIsolated(allocator: std.mem.Allocator, command: []const []const u8) !u8 {
    const config = voidbox.JailConfig{
        .name = "full-isolation",
        .rootfs_path = "/",
        .cmd = command,

        // Enable all namespaces
        .isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = true,   // Isolated network
            .uts = true,   // Isolated hostname
            .ipc = true,   // Isolated IPC
            .cgroup = true,
        },

        .resources = .{
            .mem = "1G",
            .pids = "500",
            .cpu = "100000",
        },

        .security = .{
            .no_new_privs = true,
            .seccomp_mode = .disabled,  // Can enable .strict for seccomp
            .cap_drop = "ALL",
            .cap_add = "",
        },
    };

    try voidbox.validate(&config, allocator);
    const session = try voidbox.spawn(&config, allocator);
    defer voidbox.cleanup_session(&session, allocator);

    const outcome = try voidbox.wait(&session, allocator);
    return outcome.exit_code;
}

/// Example: Minimal isolation (user namespace only)
pub fn runMinimalIsolation(allocator: std.mem.Allocator) !void {
    const config = voidbox.JailConfig{
        .name = "minimal",
        .rootfs_path = "/",
        .cmd = &[_][]const u8{ "/bin/sh", "-c", "echo 'Hello from jail'; id" },

        .isolation = .{
            .user = true,  // Only user namespace
            .pid = false,
            .mount = false,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        },

        .resources = .{},  // No resource limits

        .security = .{
            .no_new_privs = true,
        },
    };

    try voidbox.validate(&config, allocator);
    const session = try voidbox.spawn(&config, allocator);
    defer voidbox.cleanup_session(&session, allocator);
    _ = try voidbox.wait(&session, allocator);
}

/// Example: Custom filesystem actions
pub fn runWithCustomFilesystem(allocator: std.mem.Allocator) !void {
    const config = voidbox.JailConfig{
        .name = "custom-fs",
        .rootfs_path = "/",
        .cmd = &[_][]const u8{ "/bin/ls", "-la", "/tmp" },

        .isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        },

        .fs_actions = &[_]voidbox.FsAction{
            // Create fresh tmpfs for /tmp
            .{ .tmpfs = .{ .target = "/tmp", .size = "64M" } },
            // Bind mount /dev
            .{ .bind_mount = .{ .source = "/dev", .target = "/dev" } },
        },
    };

    try voidbox.validate(&config, allocator);
    const session = try voidbox.spawn(&config, allocator);
    defer voidbox.cleanup_session(&session, allocator);
    _ = try voidbox.wait(&session, allocator);
}

/// Example usage in a real program
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Voidbox Examples ===\n\n", .{});

    std.debug.print("1. Minimal isolation (user namespace only):\n", .{});
    try runMinimalIsolation(allocator);

    std.debug.print("\n2. Running isolated command:\n", .{});
    const cmd = [_][]const u8{ "/bin/sh", "-c", "echo 'Isolated!'; ps aux | head" };
    const exit_code = try runFullyIsolated(allocator, &cmd);
    std.debug.print("Command exited with code: {}\n", .{exit_code});

    std.debug.print("\n3. Custom filesystem:\n", .{});
    try runWithCustomFilesystem(allocator);
}
