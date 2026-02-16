const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const voidbox = @import("voidbox");

// ============================================================================
// Public API
// ============================================================================

/// Read isolation profile from environment
pub fn getProfile() []const u8 {
    return posix.getenv("HEXE_VOIDBOX_PROFILE") orelse "none";
}

/// Check if isolation is needed
pub fn needsIsolation(profile: []const u8) bool {
    return !std.mem.eql(u8, profile, "none");
}

/// Build a JailConfig for the given profile.
/// Caller must free returned fs_actions with allocator.
pub fn buildConfig(allocator: std.mem.Allocator, profile: []const u8, shell: []const u8) !voidbox.JailConfig {
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = shell;

    const iso = getIsolationOptions(profile);

    return voidbox.JailConfig{
        .name = "hexe-pod",
        .rootfs_path = "/",
        .cmd = cmd,
        .isolation = iso,
        .runtime = .{
            .use_pivot_root = false,
            .hostname = if (iso.uts) "hexe" else null,
        },
        .security = .{
            .no_new_privs = true,
            .cap_drop = "",
            .cap_add = "",
            .seccomp_mode = .disabled,
        },
        .fs_actions = try buildFsActions(allocator, profile),
    };
}

/// Apply isolation in an already-forked child process.
/// This is the main entry point - calls voidbox.applyIsolationInChild() directly.
pub fn applyInChild(config: voidbox.JailConfig, allocator: std.mem.Allocator) !void {
    try voidbox.applyIsolationInChild(config, allocator);
}

/// Apply cgroups in parent process (after fork, with child PID)
pub fn applyParentCgroups(child_pid: posix.pid_t, pane_uuid: ?[]const u8) void {
    const profile = getProfile();
    if (!needsIsolation(profile)) return;

    // Only sandbox and full get cgroups
    if (!std.mem.eql(u8, profile, "sandbox") and !std.mem.eql(u8, profile, "full")) return;

    const allocator = std.heap.c_allocator;

    const rel = readCgroupV2Path(allocator) catch return;
    defer allocator.free(rel);

    const uuid_short = if (pane_uuid) |uuid| uuid[0..@min(uuid.len, 8)] else "unknown";
    const dir_path = std.fmt.allocPrint(
        allocator,
        "/sys/fs/cgroup{s}/hexe/pod-{s}",
        .{ rel, uuid_short },
    ) catch return;
    defer allocator.free(dir_path);

    std.fs.cwd().makePath(dir_path) catch return;

    var buf: [128]u8 = undefined;
    const pid_line = std.fmt.bufPrint(&buf, "{d}\n", .{child_pid}) catch return;
    _ = tryWriteCgroupFile(dir_path, "cgroup.procs", pid_line);

    if (posix.getenv("HEXE_CGROUP_MEM_MAX")) |mem| {
        const line = std.fmt.bufPrint(&buf, "{s}\n", .{mem}) catch return;
        _ = tryWriteCgroupFile(dir_path, "memory.max", line);
    }
    if (posix.getenv("HEXE_CGROUP_PIDS_MAX")) |pids| {
        const line = std.fmt.bufPrint(&buf, "{s}\n", .{pids}) catch return;
        _ = tryWriteCgroupFile(dir_path, "pids.max", line);
    }
    if (posix.getenv("HEXE_CGROUP_CPU_MAX")) |cpu| {
        const line = std.fmt.bufPrint(&buf, "{s}\n", .{cpu}) catch return;
        _ = tryWriteCgroupFile(dir_path, "cpu.max", line);
    }
}

// ============================================================================
// Profile → IsolationOptions
// ============================================================================

fn getIsolationOptions(profile: []const u8) voidbox.IsolationOptions {
    if (std.mem.eql(u8, profile, "minimal")) {
        return .{
            .user = true,
            .pid = false,
            .mount = false,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    } else if (std.mem.eql(u8, profile, "balanced")) {
        return .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    } else if (std.mem.eql(u8, profile, "sandbox")) {
        return .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = true,
            .ipc = true,
            .cgroup = false,
        };
    } else if (std.mem.eql(u8, profile, "full")) {
        return .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = true,
            .uts = true,
            .ipc = true,
            .cgroup = false,
        };
    } else {
        return .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    }
}

// ============================================================================
// Profile → FsActions (bind mounts for chroot-style access)
// ============================================================================

fn buildFsActions(allocator: std.mem.Allocator, profile: []const u8) ![]const voidbox.FsAction {
    // No filesystem isolation for minimal
    if (std.mem.eql(u8, profile, "minimal")) {
        return &.{};
    }

    var actions: std.ArrayList(voidbox.FsAction) = .empty;
    errdefer actions.deinit(allocator);

    // Essential system directories (read-only)
    const ro_dirs = [_][]const u8{
        "/bin", "/usr", "/lib", "/lib64", "/etc",
    };
    for (ro_dirs) |dir| {
        if (dirExists(dir)) {
            try actions.append(allocator, .{ .ro_bind = .{ .src = dir, .dest = dir } });
        }
    }

    // Package manager directories (read-only) - nix, etc
    if (!std.mem.eql(u8, profile, "full")) {
        const pkg_dirs = [_][]const u8{
            "/nix", "/pkg", "/opt", "/run/current-system",
        };
        for (pkg_dirs) |dir| {
            if (dirExists(dir)) {
                try actions.append(allocator, .{ .ro_bind = .{ .src = dir, .dest = dir } });
            }
        }
    }

    // Home directory (read-write so user can work)
    if (posix.getenv("HOME")) |home| {
        if (dirExists(home)) {
            try actions.append(allocator, .{ .bind = .{ .src = home, .dest = home } });
        }
    }

    // Fresh /proc, /dev, /tmp
    try actions.append(allocator, .{ .proc = "/proc" });
    try actions.append(allocator, .{ .dev = "/dev" });
    try actions.append(allocator, .{ .tmpfs = .{ .dest = "/tmp" } });

    return try actions.toOwnedSlice(allocator);
}

fn dirExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Internal helpers
// ============================================================================

fn readCgroupV2Path(allocator: std.mem.Allocator) ![]u8 {
    const file = try std.fs.openFileAbsolute("/proc/self/cgroup", .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            return try allocator.dupe(u8, line[3..]);
        }
    }
    return error.CgroupV2NotFound;
}

fn tryWriteCgroupFile(dir_path: []const u8, file_name: []const u8, data: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, file_name }) catch return false;
    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch return false;
    defer file.close();
    file.writeAll(data) catch return false;
    return true;
}
