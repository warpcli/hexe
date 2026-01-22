const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/mount.h");
    @cInclude("sys/prctl.h");
});

fn envFlag(name: []const u8) bool {
    const v = posix.getenv(name) orelse return false;
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

/// Returns true when the current process should sandbox new PTY children.
pub fn enabled() bool {
    return envFlag("HEXE_POD_ISOLATE");
}

/// Returns true if isolation should be enabled, considering both the current
/// environment and any extra env that will be applied to the exec'd program.
///
/// This makes it possible for callers to request isolation without mutating
/// the parent process environment.
pub fn enabledFor(extra_env: ?[]const [2][]const u8) bool {
    if (enabled()) return true;
    const extras = extra_env orelse return false;
    for (extras) |kv| {
        if (std.mem.eql(u8, kv[0], "HEXE_POD_ISOLATE")) {
            return std.mem.eql(u8, kv[1], "1") or std.ascii.eqlIgnoreCase(kv[1], "true") or std.ascii.eqlIgnoreCase(kv[1], "yes");
        }
    }
    return false;
}

pub fn findPaneUuid(extra_env: ?[]const [2][]const u8) ?[]const u8 {
    const extras = extra_env orelse return null;
    for (extras) |kv| {
        if (std.mem.eql(u8, kv[0], "HEXE_PANE_UUID")) return kv[1];
    }
    return null;
}

fn writeProcFile(path: []const u8, data: []const u8) !void {
    const fd = try posix.open(path, .{ .ACCMODE = .WRONLY }, 0);
    defer posix.close(fd);
    _ = try posix.write(fd, data);
}

fn tryUnshareUserNs() bool {
    const rc = linux.syscall1(.unshare, linux.CLONE.NEWUSER);
    if (linux.E.init(rc) != .SUCCESS) return false;

    const uid = posix.getuid();
    const gid: u32 = @intCast(linux.syscall0(.getgid));

    // Required on many systems before writing gid_map.
    writeProcFile("/proc/self/setgroups", "deny\n") catch {};

    var buf: [64]u8 = undefined;
    const uid_line = std.fmt.bufPrint(&buf, "0 {d} 1\n", .{uid}) catch return false;
    writeProcFile("/proc/self/uid_map", uid_line) catch return false;

    const gid_line = std.fmt.bufPrint(&buf, "0 {d} 1\n", .{gid}) catch return false;
    writeProcFile("/proc/self/gid_map", gid_line) catch return false;

    // Switch to uid/gid 0 inside the namespace so we gain capabilities there.
    // Best-effort: if it fails, we still keep Landlock as the primary sandbox.
    _ = linux.syscall3(.setresgid, 0, 0, 0);
    _ = linux.syscall3(.setresuid, 0, 0, 0);

    return true;
}

fn tryUnshareMountNs() void {
    const rc = linux.syscall1(.unshare, linux.CLONE.NEWNS);
    if (linux.E.init(rc) != .SUCCESS) return;

    // Stop mount propagation from/to the host.
    _ = c.mount(null, "/", null, c.MS_REC | c.MS_PRIVATE, null);

    // Make a fresh /tmp to avoid leaking temp files across panes.
    _ = c.mount(
        "tmpfs",
        "/tmp",
        "tmpfs",
        c.MS_NOSUID | c.MS_NODEV,
        "mode=1777,size=64m",
    );
}

// Minimal Landlock uapi (avoid depending on kernel headers).
const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1;
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;

const ACCESS_EXECUTE: u64 = 1 << 0;
const ACCESS_WRITE_FILE: u64 = 1 << 1;
const ACCESS_READ_FILE: u64 = 1 << 2;
const ACCESS_READ_DIR: u64 = 1 << 3;
const ACCESS_REMOVE_DIR: u64 = 1 << 4;
const ACCESS_REMOVE_FILE: u64 = 1 << 5;
const ACCESS_MAKE_CHAR: u64 = 1 << 6;
const ACCESS_MAKE_DIR: u64 = 1 << 7;
const ACCESS_MAKE_REG: u64 = 1 << 8;
const ACCESS_MAKE_SOCK: u64 = 1 << 9;
const ACCESS_MAKE_FIFO: u64 = 1 << 10;
const ACCESS_MAKE_BLOCK: u64 = 1 << 11;
const ACCESS_MAKE_SYM: u64 = 1 << 12;
const ACCESS_REFER: u64 = 1 << 13;
const ACCESS_TRUNCATE: u64 = 1 << 14;

const ACCESS_FS_ALL: u64 = ACCESS_EXECUTE |
    ACCESS_WRITE_FILE |
    ACCESS_READ_FILE |
    ACCESS_READ_DIR |
    ACCESS_REMOVE_DIR |
    ACCESS_REMOVE_FILE |
    ACCESS_MAKE_CHAR |
    ACCESS_MAKE_DIR |
    ACCESS_MAKE_REG |
    ACCESS_MAKE_SOCK |
    ACCESS_MAKE_FIFO |
    ACCESS_MAKE_BLOCK |
    ACCESS_MAKE_SYM |
    ACCESS_REFER |
    ACCESS_TRUNCATE;

const landlock_ruleset_attr = extern struct {
    handled_access_fs: u64,
};

const landlock_path_beneath_attr = extern struct {
    allowed_access: u64,
    parent_fd: i32,
};

fn sys_landlock_create_ruleset(attr: ?*const landlock_ruleset_attr, size: usize, flags: u32) isize {
    const rc = linux.syscall3(
        .landlock_create_ruleset,
        @as(usize, @intFromPtr(attr)),
        size,
        flags,
    );
    if (linux.E.init(rc) != .SUCCESS) return -1;
    return @as(isize, @bitCast(rc));
}

fn sys_landlock_add_rule(ruleset_fd: i32, rule_type: u32, rule_attr: *const landlock_path_beneath_attr, flags: u32) isize {
    const rc = linux.syscall4(
        .landlock_add_rule,
        @as(usize, @bitCast(@as(isize, ruleset_fd))),
        rule_type,
        @as(usize, @intFromPtr(rule_attr)),
        flags,
    );
    if (linux.E.init(rc) != .SUCCESS) return -1;
    return @as(isize, @bitCast(rc));
}

fn sys_landlock_restrict_self(ruleset_fd: i32, flags: u32) isize {
    const rc = linux.syscall2(
        .landlock_restrict_self,
        @as(usize, @bitCast(@as(isize, ruleset_fd))),
        flags,
    );
    if (linux.E.init(rc) != .SUCCESS) return -1;
    return @as(isize, @bitCast(rc));
}

fn addPathRule(ruleset_fd: i32, path: []const u8, access: u64) void {
    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_z.len) return;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    // O_PATH value from Linux headers; not available consistently via libc in all builds.
    const O_PATH: c_int = 0o10000000;
    const fd = c.open(path_z[0..].ptr, O_PATH | c.O_CLOEXEC);
    if (fd < 0) return;
    defer posix.close(@intCast(fd));

    const attr = landlock_path_beneath_attr{
        .allowed_access = access,
        .parent_fd = fd,
    };
    _ = sys_landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &attr, 0);
}

fn tryApplyLandlock(cwd: ?[]const u8) void {
    // Ensure Landlock will work for unprivileged processes.
    _ = c.prctl(c.PR_SET_NO_NEW_PRIVS, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));

    // Probe kernel support.
    const abi = sys_landlock_create_ruleset(null, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 0) return;

    var ruleset_attr = landlock_ruleset_attr{ .handled_access_fs = ACCESS_FS_ALL };
    const ruleset_fd_raw = sys_landlock_create_ruleset(&ruleset_attr, @sizeOf(landlock_ruleset_attr), 0);
    if (ruleset_fd_raw < 0) return;
    const ruleset_fd: i32 = @intCast(ruleset_fd_raw);
    defer posix.close(@intCast(ruleset_fd));

    const ro = ACCESS_EXECUTE | ACCESS_READ_FILE | ACCESS_READ_DIR;
    const rw = ACCESS_FS_ALL;

    // Root must be traversable, but do not grant blanket read access.
    addPathRule(ruleset_fd, "/", ACCESS_READ_DIR);
    addPathRule(ruleset_fd, "/home", ACCESS_READ_DIR);
    addPathRule(ruleset_fd, "/var", ACCESS_READ_DIR);

    // System/runtime directories typically needed for shells and dynamically linked binaries.
    addPathRule(ruleset_fd, "/bin", ro);
    addPathRule(ruleset_fd, "/usr", ro);
    addPathRule(ruleset_fd, "/lib", ro);
    addPathRule(ruleset_fd, "/lib64", ro);
    addPathRule(ruleset_fd, "/etc", ro);
    addPathRule(ruleset_fd, "/proc", ro);
    addPathRule(ruleset_fd, "/run", ro);

    // Devices: shells/tools expect these to be usable.
    addPathRule(ruleset_fd, "/dev", ACCESS_READ_DIR);
    addPathRule(ruleset_fd, "/dev/null", rw);
    addPathRule(ruleset_fd, "/dev/zero", rw);
    addPathRule(ruleset_fd, "/dev/random", rw);
    addPathRule(ruleset_fd, "/dev/urandom", rw);
    addPathRule(ruleset_fd, "/dev/tty", rw);
    addPathRule(ruleset_fd, "/dev/ptmx", rw);
    addPathRule(ruleset_fd, "/dev/pts", rw);

    // Writable locations.
    addPathRule(ruleset_fd, "/tmp", rw);
    addPathRule(ruleset_fd, "/var/tmp", rw);

    if (cwd) |dir| {
        addPathRule(ruleset_fd, dir, rw);
    }
    if (posix.getenv("HOME")) |home| {
        addPathRule(ruleset_fd, home, rw);
    }

    _ = sys_landlock_restrict_self(ruleset_fd, 0);
}

/// Apply best-effort isolation to a freshly forked PTY child.
///
/// By default, this uses Landlock and skips user namespaces. User namespaces
/// are opt-in because partial failures can produce an unmapped uid ("nobody")
/// and break normal shell behavior.
pub fn applyChildIsolation(cwd: ?[]const u8) void {
    if (envFlag("HEXE_POD_ISOLATE_USERNS")) {
        if (tryUnshareUserNs()) {
            tryUnshareMountNs();
        }
    }
    tryApplyLandlock(cwd);
}

fn readCgroupV2Path(allocator: std.mem.Allocator) ?[]u8 {
    var file = std.fs.openFileAbsolute("/proc/self/cgroup", .{}) catch return null;
    defer file.close();
    const data = file.readToEndAlloc(allocator, 16 * 1024) catch return null;
    errdefer allocator.free(data);

    // v2 format: "0::/some/path"
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            const p = line[3..];
            const out = allocator.dupe(u8, p) catch return null;
            allocator.free(data);
            return out;
        }
    }

    allocator.free(data);
    return null;
}

fn tryWriteFileAbsolute(path: []const u8, data: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch return false;
    defer file.close();
    file.writeAll(data) catch return false;
    return true;
}

fn tryWriteCgroupFile(dir_path: []const u8, file_name: []const u8, data: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, file_name }) catch return false;
    return tryWriteFileAbsolute(p, data);
}

/// Best-effort cgroup v2 containment. If cgroups are not delegated, this
/// silently does nothing.
///
/// Environment overrides:
/// - `HEXE_CGROUP_PIDS_MAX` (default: 512)
/// - `HEXE_CGROUP_MEM_MAX` (no default)
/// - `HEXE_CGROUP_CPU_MAX` (no default; e.g. "50000 100000")
pub fn applyChildCgroup(extra_env: ?[]const [2][]const u8, child_pid: posix.pid_t) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Only support cgroup v2.
    var ctrls = std.fs.openFileAbsolute("/sys/fs/cgroup/cgroup.controllers", .{}) catch return;
    ctrls.close();

    const rel = readCgroupV2Path(allocator) orelse return;
    defer allocator.free(rel);

    const uuid = findPaneUuid(extra_env) orelse "unknown";
    const short = uuid[0..@min(uuid.len, 8)];
    const dir_path = std.fmt.allocPrint(allocator, "/sys/fs/cgroup{s}/hexe/pod-{s}", .{ rel, short }) catch return;
    defer allocator.free(dir_path);

    // Create cgroup directory (with parents) if we have delegation.
    std.fs.cwd().makePath(dir_path) catch return;

    var line_buf: [128]u8 = undefined;

    const pids_max = posix.getenv("HEXE_CGROUP_PIDS_MAX") orelse "512";
    const pids_line = std.fmt.bufPrint(&line_buf, "{s}\n", .{pids_max}) catch return;
    _ = tryWriteCgroupFile(dir_path, "pids.max", pids_line);

    if (posix.getenv("HEXE_CGROUP_MEM_MAX")) |mem_max| {
        const mem_line = std.fmt.bufPrint(&line_buf, "{s}\n", .{mem_max}) catch return;
        _ = tryWriteCgroupFile(dir_path, "memory.max", mem_line);
    }
    if (posix.getenv("HEXE_CGROUP_CPU_MAX")) |cpu_max| {
        const cpu_line = std.fmt.bufPrint(&line_buf, "{s}\n", .{cpu_max}) catch return;
        _ = tryWriteCgroupFile(dir_path, "cpu.max", cpu_line);
    }

    var pid_buf: [32]u8 = undefined;
    const pid_line = std.fmt.bufPrint(&pid_buf, "{d}\n", .{child_pid}) catch return;
    _ = tryWriteCgroupFile(dir_path, "cgroup.procs", pid_line);
}
