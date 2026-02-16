const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const voidbox = @import("voidbox");

const c = @cImport({
    @cInclude("sys/mount.h");
    @cInclude("sys/prctl.h");
});

/// Parse voidbox configuration from environment
pub fn configFromEnv(allocator: std.mem.Allocator, shell: []const u8, cwd: ?[]const u8) !voidbox.JailConfig {
    _ = cwd; // cwd is passed to applyChildIsolation later, not used here
    const profile = posix.getenv("HEXE_VOIDBOX_PROFILE") orelse "none";

    // Parse isolation options
    var isolation = voidbox.IsolationOptions{};
    if (std.mem.eql(u8, profile, "none")) {
        isolation = .{
            .user = false,
            .pid = false,
            .mount = false,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    } else if (std.mem.eql(u8, profile, "minimal")) {
        isolation = .{
            .user = true,
            .pid = false,
            .mount = false,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    } else if (std.mem.eql(u8, profile, "balanced")) {
        isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    } else if (std.mem.eql(u8, profile, "sandbox")) {
        // Full isolation but WITH network access
        isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,  // Network allowed
            .uts = true,
            .ipc = true,
            .cgroup = true,
        };
    } else if (std.mem.eql(u8, profile, "full")) {
        isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = true,   // Network blocked
            .uts = true,
            .ipc = true,
            .cgroup = true,
        };
    } else {
        // default profile
        isolation = .{
            .user = true,
            .pid = true,
            .mount = false,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        };
    }

    // Parse resource limits
    var resources = voidbox.ResourceLimits{};
    if (posix.getenv("HEXE_CGROUP_MEM_MAX")) |mem| {
        resources.mem = mem;
    }
    if (posix.getenv("HEXE_CGROUP_PIDS_MAX")) |pids| {
        resources.pids = pids;
    }
    if (posix.getenv("HEXE_CGROUP_CPU_MAX")) |cpu| {
        resources.cpu = cpu;
    }

    // Build command array
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = shell;

    // Build filesystem actions based on profile
    const fs_actions = try buildFsActions(allocator, profile);

    const config = voidbox.JailConfig{
        .name = "hexe-pod",
        .rootfs_path = "/",
        .cmd = cmd,
        .isolation = isolation,
        .resources = resources,
        .security = .{
            .no_new_privs = true,
            .cap_drop = "",
            .cap_add = "",
            .seccomp_mode = .disabled,
        },
        .fs_actions = fs_actions,
    };

    return config;
}

/// Build filesystem actions based on isolation profile
fn buildFsActions(allocator: std.mem.Allocator, profile: []const u8) ![]const voidbox.FsAction {
    var actions: std.ArrayList(voidbox.FsAction) = .empty;
    errdefer actions.deinit(allocator);

    if (std.mem.eql(u8, profile, "none")) {
        // No filesystem isolation
        return try actions.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, profile, "minimal")) {
        // Only private /tmp
        try actions.append(allocator, .{ .tmpfs = .{ .dest = "/tmp" } });
        return try actions.toOwnedSlice(allocator);
    }

    // For default, balanced, sandbox, full: bind mount essential directories
    const bind_essential = std.mem.eql(u8, profile, "default") or
                          std.mem.eql(u8, profile, "balanced") or
                          std.mem.eql(u8, profile, "sandbox") or
                          std.mem.eql(u8, profile, "full");

    if (bind_essential) {
        // Always bind these system directories (read-only for safety)
        try actions.append(allocator, .{ .ro_bind = .{ .src = "/bin", .dest = "/bin" } });
        try actions.append(allocator, .{ .ro_bind = .{ .src = "/usr", .dest = "/usr" } });
        try actions.append(allocator, .{ .ro_bind = .{ .src = "/lib", .dest = "/lib" } });
        try actions.append(allocator, .{ .ro_bind = .{ .src = "/lib64", .dest = "/lib64" } });

        // For all profiles except "full", also bind package directories
        if (!std.mem.eql(u8, profile, "full")) {
            try actions.append(allocator, .{ .ro_bind = .{ .src = "/nix", .dest = "/nix" } });
            try actions.append(allocator, .{ .ro_bind = .{ .src = "/pkg", .dest = "/pkg" } });
            try actions.append(allocator, .{ .ro_bind = .{ .src = "/opt", .dest = "/opt" } });

            // Bind user's home directory (read-write so they can work)
            if (posix.getenv("HOME")) |home| {
                try actions.append(allocator, .{ .bind = .{ .src = home, .dest = home } });
            }
        }

        // Private /tmp for all
        try actions.append(allocator, .{ .tmpfs = .{ .dest = "/tmp" } });
    }

    return try actions.toOwnedSlice(allocator);
}

/// Apply voidbox isolation in child process (after PTY setup, before exec)
/// This is called in the child process after fork and PTY dup2
pub fn applyChildIsolation(config: *const voidbox.JailConfig, cwd: ?[]const u8) !void {
    // Enable no_new_privs (security requirement)
    _ = c.prctl(c.PR_SET_NO_NEW_PRIVS, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));

    // Apply namespace isolation
    try enterNamespaces(config.isolation);

    // Setup mount namespace if enabled
    if (config.isolation.mount) {
        try setupMountNamespace(cwd);
    }
}

/// Apply cgroups in parent process (after fork, with child PID)
pub fn applyParentCgroups(
    allocator: std.mem.Allocator,
    config: *const voidbox.JailConfig,
    child_pid: posix.pid_t,
    pane_uuid: ?[]const u8,
) !void {
    if (config.resources.mem == null and
        config.resources.pids == null and
        config.resources.cpu == null) {
        return; // No cgroup limits configured
    }

    // Read current cgroup path
    const rel = readCgroupV2Path(allocator) catch return;
    defer allocator.free(rel);

    const uuid_short = if (pane_uuid) |uuid| uuid[0..@min(uuid.len, 8)] else "unknown";
    const dir_path = try std.fmt.allocPrint(
        allocator,
        "/sys/fs/cgroup{s}/hexe/pod-{s}",
        .{ rel, uuid_short },
    );
    defer allocator.free(dir_path);

    // Create cgroup directory
    std.fs.cwd().makePath(dir_path) catch return;

    var buf: [128]u8 = undefined;

    // Apply memory limit
    if (config.resources.mem) |mem| {
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{mem});
        _ = tryWriteCgroupFile(dir_path, "memory.max", line);
    }

    // Apply PIDs limit
    if (config.resources.pids) |pids| {
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{pids});
        _ = tryWriteCgroupFile(dir_path, "pids.max", line);
    }

    // Apply CPU limit
    if (config.resources.cpu) |cpu| {
        const line = try std.fmt.bufPrint(&buf, "{s}\n", .{cpu});
        _ = tryWriteCgroupFile(dir_path, "cpu.max", line);
    }

    // Move process to cgroup
    const pid_line = try std.fmt.bufPrint(&buf, "{d}\n", .{child_pid});
    _ = tryWriteCgroupFile(dir_path, "cgroup.procs", pid_line);
}

// ============================================================================
// Internal implementation
// ============================================================================

fn enterNamespaces(isolation: voidbox.IsolationOptions) !void {
    var flags: usize = 0;

    if (isolation.user) flags |= linux.CLONE.NEWUSER;
    if (isolation.pid) flags |= linux.CLONE.NEWPID;
    if (isolation.mount) flags |= linux.CLONE.NEWNS;
    if (isolation.net) flags |= linux.CLONE.NEWNET;
    if (isolation.uts) flags |= linux.CLONE.NEWUTS;
    if (isolation.ipc) flags |= linux.CLONE.NEWIPC;
    if (isolation.cgroup) flags |= linux.CLONE.NEWCGROUP;

    if (flags == 0) return;

    // User namespace must be created first
    if (isolation.user) {
        const rc = linux.syscall1(.unshare, linux.CLONE.NEWUSER);
        if (linux.E.init(rc) != .SUCCESS) return error.UnshareUserFailed;

        try setupUserNamespace();
        flags &= ~@as(usize, linux.CLONE.NEWUSER);
    }

    // Create remaining namespaces
    if (flags != 0) {
        const rc = linux.syscall1(.unshare, flags);
        if (linux.E.init(rc) != .SUCCESS) return error.UnshareNamespacesFailed;
    }
}

fn setupUserNamespace() !void {
    const uid = posix.getuid();
    const gid: u32 = @intCast(linux.syscall0(.getgid));

    // Required before writing gid_map
    writeProcFile("/proc/self/setgroups", "deny\n") catch {};

    var buf: [64]u8 = undefined;

    const uid_line = try std.fmt.bufPrint(&buf, "0 {d} 1\n", .{uid});
    try writeProcFile("/proc/self/uid_map", uid_line);

    const gid_line = try std.fmt.bufPrint(&buf, "0 {d} 1\n", .{gid});
    try writeProcFile("/proc/self/gid_map", gid_line);

    // Switch to uid/gid 0 inside namespace
    _ = linux.syscall3(.setresgid, 0, 0, 0);
    _ = linux.syscall3(.setresuid, 0, 0, 0);
}

fn setupMountNamespace(cwd: ?[]const u8) !void {
    const MS_REC: c_ulong = 16384;
    const MS_PRIVATE: c_ulong = 262144;
    const MS_NOSUID: c_ulong = 2;
    const MS_NODEV: c_ulong = 4;

    // Stop mount propagation
    if (c.mount(null, "/", null, MS_REC | MS_PRIVATE, null) != 0) {
        return error.MountPrivateFailed;
    }

    // Create fresh /tmp
    _ = c.mount(
        "tmpfs",
        "/tmp",
        "tmpfs",
        MS_NOSUID | MS_NODEV,
        "mode=1777,size=128m",
    );

    // Optionally bind mount the working directory if specified
    if (cwd) |dir| {
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (dir.len < path_buf.len) {
            @memcpy(path_buf[0..dir.len], dir);
            path_buf[dir.len] = 0;
            const dir_z: [*:0]const u8 = path_buf[0..dir.len :0];
            _ = c.mount(dir_z, dir_z, null, c.MS_BIND | MS_REC, null);
        }
    }
}

fn writeProcFile(path: []const u8, data: []const u8) !void {
    const fd = try posix.open(path, .{ .ACCMODE = .WRONLY }, 0);
    defer posix.close(fd);
    _ = try posix.write(fd, data);
}

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
