const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/socket.h");
});

const linux = std.os.linux;

/// Unix credentials structure for SO_PEERCRED
const ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

/// SO_PEERCRED option value (from Linux headers)
const SO_PEERCRED: u32 = 17;

/// Verify connecting peer has same UID as current process (security check)
fn verifyPeerCredentials(fd: posix.fd_t) bool {
    var cred: ucred = undefined;
    var len: linux.socklen_t = @sizeOf(ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, SO_PEERCRED, @ptrCast(&cred), &len);
    if (rc != 0) {
        debugLog("SO_PEERCRED failed", .{});
        return false;
    }
    const my_uid = linux.getuid();
    if (cred.uid != my_uid) {
        debugLog("peer uid {d} != our uid {d}, rejecting", .{ cred.uid, my_uid });
        return false;
    }
    return true;
}

const core = @import("core");
const pod_protocol = core.pod_protocol;
const pod_meta = core.pod_meta;
const wire = core.wire;

var pod_debug: bool = false;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!pod_debug) return;
    std.debug.print("[pod] " ++ fmt ++ "\n", args);
}

const PodUplink = struct {
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    fd: ?posix.fd_t = null,
    last_sent_ms: i64 = 0,
    last_cwd: ?[]u8 = null,
    last_fg_process: ?[]u8 = null,
    last_fg_pid: ?i32 = null,

    pub fn init(allocator: std.mem.Allocator, uuid: [32]u8) PodUplink {
        return .{ .allocator = allocator, .uuid = uuid };
    }

    pub fn deinit(self: *PodUplink) void {
        if (self.fd) |fd| posix.close(fd);
        if (self.last_cwd) |s| self.allocator.free(s);
        if (self.last_fg_process) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn tick(self: *PodUplink, child_pid: posix.pid_t) void {
        const now_ms: i64 = std.time.milliTimestamp();
        if (now_ms - self.last_sent_ms < 500) return;
        self.last_sent_ms = now_ms;

        const proc_cwd = readProcCwd(self.allocator, child_pid) catch null;
        defer if (proc_cwd) |s| self.allocator.free(s);

        const fg = readProcForeground(self.allocator, child_pid) catch null;
        defer if (fg) |v| {
            self.allocator.free(v.name);
        };

        var changed = false;
        if (!optStrEql(self.last_cwd, proc_cwd)) changed = true;
        const fg_name = if (fg) |v| v.name else null;
        const fg_pid = if (fg) |v| v.pid else null;
        if (!optStrEql(self.last_fg_process, fg_name)) changed = true;
        if (!optIntEql(i32, self.last_fg_pid, fg_pid)) changed = true;
        if (!changed) return;

        if (self.last_cwd) |s| self.allocator.free(s);
        self.last_cwd = if (proc_cwd) |s| self.allocator.dupe(u8, s) catch null else null;

        if (self.last_fg_process) |s| self.allocator.free(s);
        self.last_fg_process = if (fg_name) |s| self.allocator.dupe(u8, s) catch null else null;
        self.last_fg_pid = fg_pid;

        if (!self.ensureConnected()) return;

        const fd = self.fd.?;

        debugLog("uplink tick: sending updates", .{});

        // Send CwdChanged if cwd is available.
        if (proc_cwd) |cwd_str| {
            var cwd_msg: wire.CwdChanged = .{
                .uuid = self.uuid,
                .cwd_len = @intCast(@min(cwd_str.len, std.math.maxInt(u16))),
            };
            const trails = [_][]const u8{cwd_str[0..cwd_msg.cwd_len]};
            wire.writeControlMsg(fd, .cwd_changed, std.mem.asBytes(&cwd_msg), &trails) catch {
                self.disconnect();
                return;
            };
        }

        // Send FgChanged if foreground process info is available.
        if (fg_name) |name_str| {
            var fg_msg: wire.FgChanged = .{
                .uuid = self.uuid,
                .pid = fg_pid orelse 0,
                .name_len = @intCast(@min(name_str.len, std.math.maxInt(u16))),
            };
            const trails = [_][]const u8{name_str[0..fg_msg.name_len]};
            wire.writeControlMsg(fd, .fg_changed, std.mem.asBytes(&fg_msg), &trails) catch {
                self.disconnect();
                return;
            };
        }
    }

    fn ensureConnected(self: *PodUplink) bool {
        if (self.fd != null) return true;

        const ses_path = core.ipc.getSesSocketPath(self.allocator) catch return false;
        defer self.allocator.free(ses_path);

        const client = core.ipc.Client.connect(ses_path) catch return false;
        const fd = client.fd;

        // Binary handshake: send 0x03 + 16 raw UUID bytes.
        var handshake: [17]u8 = undefined;
        handshake[0] = wire.SES_HANDSHAKE_POD_CTL;
        // Convert 32-char hex UUID to 16 binary bytes.
        const uuid_bin = core.uuid.hexToBin(self.uuid) orelse {
            posix.close(fd);
            return false;
        };
        @memcpy(handshake[1..17], &uuid_bin);
        wire.writeAll(fd, &handshake) catch {
            posix.close(fd);
            return false;
        };

        self.fd = fd;
        debugLog("uplink connected fd={d}", .{fd});
        return true;
    }

    fn disconnect(self: *PodUplink) void {
        debugLog("uplink disconnected", .{});
        if (self.fd) |fd| posix.close(fd);
        self.fd = null;
    }
};

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optIntEql(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn readProcCwd(allocator: std.mem.Allocator, pid: posix.pid_t) !?[]u8 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid});
    var tmp: [std.fs.max_path_bytes]u8 = undefined;
    const link = posix.readlink(path, &tmp) catch return null;
    return try allocator.dupe(u8, link);
}

fn readProcForeground(allocator: std.mem.Allocator, child_pid: posix.pid_t) !?struct { name: []u8, pid: i32 } {
    if (child_pid <= 0) return null;

    // /proc/<pid>/stat field 8 after the comm+state is tpgid.
    var stat_path_buf: [64]u8 = undefined;
    const stat_path = try std.fmt.bufPrint(&stat_path_buf, "/proc/{d}/stat", .{child_pid});
    const stat_file = std.fs.openFileAbsolute(stat_path, .{}) catch return null;
    defer stat_file.close();

    var stat_buf: [512]u8 = undefined;
    const stat_len = stat_file.read(&stat_buf) catch return null;
    if (stat_len == 0) return null;
    const stat = stat_buf[0..stat_len];

    const right_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    if (right_paren + 2 >= stat.len) return null;
    const rest = stat[right_paren + 2 ..];

    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var idx: usize = 0;
    var tpgid: ?i32 = null;
    while (it.next()) |tok| {
        idx += 1;
        if (idx == 6) {
            const v = std.fmt.parseInt(i32, tok, 10) catch return null;
            if (v > 0) tpgid = v;
            break;
        }
    }
    if (tpgid == null) return null;

    var comm_path_buf: [64]u8 = undefined;
    const comm_path = try std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{tpgid.?});
    const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch return null;
    defer comm_file.close();
    var comm_buf: [128]u8 = undefined;
    const comm_len = comm_file.read(&comm_buf) catch return null;
    if (comm_len == 0) return null;
    const end = if (comm_buf[comm_len - 1] == '\n') comm_len - 1 else comm_len;

    const name = try allocator.dupe(u8, comm_buf[0..end]);
    return .{ .name = name, .pid = tpgid.? };
}

fn setBlocking(fd: posix.fd_t) void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    const new_flags: usize = flags & ~@as(usize, @intCast(c.O_NONBLOCK));
    _ = posix.fcntl(fd, posix.F.SETFL, new_flags) catch {};
}

pub const PodArgs = struct {
    daemon: bool = true,
    uuid: []const u8,
    name: ?[]const u8 = null,
    socket_path: []const u8,
    shell: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    write_meta: bool = true,
    write_alias: bool = false,
    debug: bool = false,
    log_file: ?[]const u8 = null,
    /// When true, print a single JSON line on stdout once ready.
    emit_ready: bool = false,
};

/// Run a per-pane pod process.
///
/// In normal operation pods are launched by `hexe-ses`.
pub fn run(args: PodArgs) !void {
    // Ignore SIGPIPE so writes to disconnected mux sockets return EPIPE
    // instead of killing the pod process. This is critical for surviving
    // mux detach (terminal close) while the shell is producing output.
    const sigpipe_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.PIPE, &sigpipe_action, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (args.uuid.len != 32) return error.InvalidUuid;

    const sh = args.shell orelse (posix.getenv("SHELL") orelse "/bin/sh");
    const log_path: ?[]const u8 = if (args.log_file) |path| (if (path.len > 0) path else null) else if (args.debug) "/tmp/hexe" else null;

    if (args.daemon) {
        try daemonize(log_path);
    } else if (log_path) |path| {
        redirectStderrToLog(path);
    }

    // Best-effort: name this process for `ps` discovery.
    setProcessName(args.name);

    var pod = try Pod.init(allocator, args.uuid, args.socket_path, sh, args.cwd, args.name);
    defer pod.deinit();

    // Best-effort: write grep-friendly .meta sidecar for discovery.
    const created_at: i64 = std.time.timestamp();
    if (args.write_meta) {
        writePodMetaSidecar(allocator, args.uuid, args.name, args.cwd, args.labels, @intCast(c.getpid()), pod.pty.child_pid, created_at) catch |e| {
            core.logging.logError("pod", "writePodMetaSidecar failed", e);
        };
    }

    var created_alias_path: ?[]const u8 = null;
    defer if (created_alias_path) |p| allocator.free(p);

    // Optional: create alias symlink pod@<name>.sock -> pod-<uuid>.sock
    if (args.write_alias and args.name != null and args.name.?.len > 0) {
        created_alias_path = createAliasSymlink(allocator, args.name.?, args.socket_path) catch null;
    }

    pod_debug = args.debug;
    debugLog("started uuid={s} socket={s} name={s}", .{ args.uuid[0..@min(args.uuid.len, 8)], args.socket_path, args.name orelse "(none)" });

    if (args.emit_ready) {
        // IMPORTANT: write handshake to stdout (ses reads stdout).
        const stdout = std.fs.File.stdout();
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pod_ready\",\"uuid\":\"{s}\",\"pid\":{d}}}\n", .{ args.uuid, pod.pty.child_pid });
        try stdout.writeAll(msg);
    }

    try pod.run(.{ .write_meta = args.write_meta, .created_at = created_at, .name = args.name, .labels = args.labels });

    // Best-effort cleanup on exit.
    if (args.write_meta) {
        deletePodMetaSidecar(allocator, args.uuid) catch |e| {
            core.logging.logError("pod", "deletePodMetaSidecar failed", e);
        };
    }
    if (created_alias_path) |p| {
        std.fs.cwd().deleteFile(p) catch {};
    }
}

fn setProcessName(name: ?[]const u8) void {
    if (name == null or name.?.len == 0) return;

    // Linux prctl(PR_SET_NAME) sets the comm field, max 15 bytes + NUL.
    // Best-effort: ignore errors / non-linux.
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return;

    const pc = @cImport({
        @cInclude("sys/prctl.h");
    });

    var buf: [16]u8 = .{0} ** 16;
    // Prefix helps scanning; keep ASCII and short.
    const prefix = "hexe-pod:";
    var i: usize = 0;
    while (i < prefix.len and i < buf.len - 1) : (i += 1) {
        buf[i] = prefix[i];
    }
    const raw = name.?;
    for (raw) |ch| {
        if (i >= buf.len - 1) break;
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        buf[i] = if (ok) ch else '_';
        i += 1;
    }
    buf[i] = 0;
    _ = pc.prctl(pc.PR_SET_NAME, @as(*const anyopaque, @ptrCast(&buf)), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
}

fn writePodMetaSidecar(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: ?[]const u8,
    cwd: ?[]const u8,
    labels: ?[]const u8,
    pod_pid: std.posix.pid_t,
    child_pid: std.posix.pid_t,
    created_at: i64,
) !void {
    var meta = try pod_meta.PodMeta.init(
        allocator,
        uuid,
        name,
        pod_pid,
        child_pid,
        cwd,
        false,
        labels,
        created_at,
    );
    defer meta.deinit();

    const path = try meta.metaPath(allocator);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.cwd().makePath(dir) catch {};

    const line = try meta.formatMetaLine(allocator);
    defer allocator.free(line);

    var f = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o644 });
    defer f.close();
    try f.writeAll(line);
    try f.writeAll("\n");
}

fn createAliasSymlink(allocator: std.mem.Allocator, raw_name: []const u8, target_socket_path: []const u8) ![]const u8 {
    // Create pod@<name>.sock -> pod-<uuid>.sock in the socket dir.
    const base_alias = try pod_meta.PodMeta.aliasSocketPath(allocator, raw_name);
    defer allocator.free(base_alias);

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const alias_path = if (attempt == 0) blk: {
            break :blk try allocator.dupe(u8, base_alias);
        } else blk: {
            // Insert suffix before ".sock".
            const dot = std.mem.lastIndexOfScalar(u8, base_alias, '.') orelse base_alias.len;
            break :blk try std.fmt.allocPrint(allocator, "{s}-{d}{s}", .{ base_alias[0..dot], attempt + 1, base_alias[dot..] });
        };
        // Do not defer free on success; return it.

        // Remove existing alias if it points to us; otherwise keep trying.
        std.fs.cwd().deleteFile(alias_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {},
        };

        // Try create. If collision races, just try next.
        std.fs.cwd().symLink(target_socket_path, alias_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(alias_path);
                continue;
            },
            else => {
                allocator.free(alias_path);
                return err;
            },
        };

        return alias_path;
    }

    return error.AliasFailed;
}

fn deletePodMetaSidecar(allocator: std.mem.Allocator, uuid: []const u8) !void {
    if (uuid.len != 32) return;
    var tmp = try pod_meta.PodMeta.init(allocator, uuid, null, 0, 0, null, false, null, 0);
    defer tmp.deinit();
    const path = try tmp.metaPath(allocator);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

fn daemonize(log_file: ?[]const u8) !void {
    // First fork
    const pid1 = try posix.fork();
    if (pid1 != 0) posix.exit(0);

    _ = posix.setsid() catch {};

    // Second fork
    const pid2 = try posix.fork();
    if (pid2 != 0) posix.exit(0);

    // Redirect stdin/stdout/stderr to /dev/null
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    posix.dup2(devnull, posix.STDIN_FILENO) catch {};
    posix.dup2(devnull, posix.STDOUT_FILENO) catch {};
    if (log_file) |path| {
        const logfd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch {
            posix.dup2(devnull, posix.STDERR_FILENO) catch {};
            if (devnull > 2) posix.close(devnull);
            std.posix.chdir("/") catch {};
            return;
        };
        posix.dup2(logfd, posix.STDERR_FILENO) catch {};
        if (logfd > 2) posix.close(logfd);
    } else {
        posix.dup2(devnull, posix.STDERR_FILENO) catch {};
    }
    if (devnull > 2) posix.close(devnull);

    std.posix.chdir("/") catch {};
}

fn redirectStderrToLog(log_path: []const u8) void {
    const logfd = posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch return;
    posix.dup2(logfd, posix.STDERR_FILENO) catch {};
    if (logfd > 2) posix.close(logfd);
}

const RingBuffer = struct {
    buf: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn capacity(self: *const RingBuffer) usize {
        return self.buf.len;
    }

    pub fn available(self: *const RingBuffer) usize {
        return self.buf.len - self.len;
    }

    pub fn isFull(self: *const RingBuffer) bool {
        return self.len == self.buf.len;
    }

    pub fn init(allocator: std.mem.Allocator, cap_bytes: usize) !RingBuffer {
        return .{ .buf = try allocator.alloc(u8, cap_bytes) };
    }

    pub fn deinit(self: *RingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn clear(self: *RingBuffer) void {
        self.start = 0;
        self.len = 0;
    }

    pub fn append(self: *RingBuffer, data: []const u8) void {
        if (self.buf.len == 0) return;
        if (data.len >= self.buf.len) {
            // Keep only last capacity bytes.
            const tail = data[data.len - self.buf.len ..];
            @memcpy(self.buf, tail);
            self.start = 0;
            self.len = self.buf.len;
            return;
        }

        const cap = self.buf.len;
        var drop: usize = 0;
        if (self.len + data.len > cap) {
            drop = self.len + data.len - cap;
        }
        if (drop > 0) {
            self.start = (self.start + drop) % cap;
            self.len -= drop;
        }

        // Write at end.
        const end = (self.start + self.len) % cap;
        const first = @min(cap - end, data.len);
        @memcpy(self.buf[end .. end + first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.buf[0 .. data.len - first], data[first..]);
        }
        self.len += data.len;
    }

    /// Append without dropping any existing bytes.
    /// Returns false if there isn't enough remaining capacity.
    pub fn appendNoDrop(self: *RingBuffer, data: []const u8) bool {
        if (self.buf.len == 0) return false;
        if (data.len > self.available()) return false;

        const cap = self.buf.len;
        const end = (self.start + self.len) % cap;
        const first = @min(cap - end, data.len);
        @memcpy(self.buf[end .. end + first], data[0..first]);
        if (first < data.len) {
            @memcpy(self.buf[0 .. data.len - first], data[first..]);
        }
        self.len += data.len;
        return true;
    }

    pub fn copyOut(self: *const RingBuffer, out: []u8) usize {
        const n = @min(out.len, self.len);
        if (n == 0) return 0;

        const cap = self.buf.len;
        const first = @min(cap - self.start, n);
        @memcpy(out[0..first], self.buf[self.start .. self.start + first]);
        if (first < n) {
            @memcpy(out[first..n], self.buf[0 .. n - first]);
        }
        return n;
    }
};

const Pod = struct {
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    pty: core.Pty,
    server: core.IpcServer,
    client: ?core.IpcConnection = null,
    backlog: RingBuffer,
    reader: pod_protocol.Reader,
    pty_paused: bool = false,

    uplink: PodUplink,

    const RunOptions = struct {
        write_meta: bool,
        created_at: i64,
        name: ?[]const u8,
        labels: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, uuid_str: []const u8, socket_path: []const u8, shell: []const u8, cwd: ?[]const u8, pod_name: ?[]const u8) !Pod {
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const extra_env = [_][2][]const u8{
            .{ "HEXE_PANE_UUID", uuid_str },
            .{ "HEXE_POD_NAME", pod_name orelse "" },
            .{ "HEXE_POD_SOCKET", socket_path },
        };
        var pty = try core.Pty.spawnWithEnv(shell, cwd, &extra_env);
        errdefer pty.close();

        var server = try core.ipc.Server.init(allocator, socket_path);
        errdefer server.deinit();

        var backlog = try RingBuffer.init(allocator, 4 * 1024 * 1024);
        errdefer backlog.deinit(allocator);

        var reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
        errdefer reader.deinit(allocator);

        return .{
            .allocator = allocator,
            .uuid = uuid,
            .pty = pty,
            .server = server,
            .backlog = backlog,
            .reader = reader,
            .uplink = PodUplink.init(allocator, uuid),
        };
    }

    pub fn deinit(self: *Pod) void {
        if (self.client) |*client| {
            client.close();
        }
        self.server.deinit();
        self.pty.close();
        self.backlog.deinit(self.allocator);
        self.reader.deinit(self.allocator);
        self.uplink.deinit();
    }

    pub fn run(self: *Pod, opts: RunOptions) !void {
        var poll_fds: [3]posix.pollfd = undefined;
        var buf = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(buf);
        const backlog_tmp = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(backlog_tmp);

        var last_meta_ms: i64 = 0;

        while (true) {
            // Phase 2: POD is source of truth; periodically push metadata to SES.
            self.uplink.tick(self.pty.child_pid);

            // Periodically refresh sidecar meta so PID/cwd changes are reflected.
            if (opts.write_meta) {
                const now_ms: i64 = std.time.milliTimestamp();
                if (now_ms - last_meta_ms >= 1000) {
                    // CWD: if we see OSC 7, prefer it; otherwise keep initial cwd.
                    const live_cwd = self.lastOsc7Cwd();
                    writePodMetaSidecar(self.allocator, self.uuid[0..], opts.name, live_cwd, opts.labels, @intCast(c.getpid()), self.pty.child_pid, opts.created_at) catch {};
                    last_meta_ms = now_ms;
                }
            }
            // Exit if the child shell/process exited.
            if (self.pty.pollStatus() != null) break;

            // server socket
            poll_fds[0] = .{ .fd = self.server.getFd(), .events = posix.POLL.IN, .revents = 0 };
            // pty
            if (self.client == null and self.backlog.isFull()) {
                self.pty_paused = true;
            }
            const pty_events: i16 = if (self.pty_paused)
                @intCast(posix.POLL.HUP | posix.POLL.ERR)
            else
                @intCast(posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR);
            poll_fds[1] = .{ .fd = self.pty.master_fd, .events = pty_events, .revents = 0 };
            // client (optional)
            poll_fds[2] = .{ .fd = if (self.client) |client_conn| client_conn.fd else -1, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };

            _ = posix.poll(&poll_fds, 1000) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };

            // Accept new connection.
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                if (self.server.tryAccept() catch null) |conn| {
                    // Security: verify peer has same UID
                    if (!verifyPeerCredentials(conn.fd)) {
                        var tmp = conn;
                        tmp.close();
                        continue;
                    }

                    // Peek first byte to distinguish connection type.
                    var peek_byte: [1]u8 = undefined;
                    const peeked = posix.read(conn.fd, &peek_byte) catch 0;

                    if (peeked > 0 and peek_byte[0] == wire.POD_HANDSHAKE_SES_VT) {
                        // SES VT channel (③) — treat as main client.
                        debugLog("accept: SES VT client fd={d}", .{conn.fd});
                        self.acceptVtClient(conn, backlog_tmp);
                    } else if (peeked > 0 and peek_byte[0] == wire.POD_HANDSHAKE_SHP_CTL) {
                        // SHP binary control (⑤) — read binary control messages.
                        debugLog("accept: SHP ctl fd={d}", .{conn.fd});
                        self.handleBinaryShpConnection(conn);
                    } else if (peeked > 0 and peek_byte[0] == wire.POD_HANDSHAKE_AUX_INPUT) {
                        // Auxiliary input (e.g., hexe pod send) — inject frames without replacing client.
                        debugLog("accept: aux input fd={d}", .{conn.fd});
                        self.handleAuxInput(conn);
                    } else {
                        // Unknown handshake — reject.
                        debugLog("accept: unknown handshake 0x{x:0>2} fd={d}", .{ if (peeked > 0) peek_byte[0] else @as(u8, 0), conn.fd });
                        var tmp_conn = conn;
                        tmp_conn.close();
                    }
                }
            }

            // Drain PTY output.
            if (poll_fds[1].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                break;
            }
            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                // If the mux is disconnected and backlog is full, pause PTY
                // reads to apply backpressure instead of silently dropping.
                if (self.client == null) {
                    const free = self.backlog.available();
                    if (free == 0) {
                        self.pty_paused = true;
                        continue;
                    }

                    const read_buf = buf[0..@min(buf.len, free)];
                    const n = self.pty.read(read_buf) catch |err| switch (err) {
                        error.WouldBlock => 0,
                        else => return err,
                    };
                    if (n == 0) {
                        // EOF => child exited / PTY closed.
                        break;
                    }
                    const data = read_buf[0..n];
                    if (containsClearSeq(data)) {
                        self.backlog.clear();
                    }
                    if (!self.backlog.appendNoDrop(data)) {
                        // Shouldn't happen due to bounded read, but be safe.
                        self.pty_paused = true;
                    } else if (self.backlog.isFull()) {
                        self.pty_paused = true;
                    }
                    continue;
                }

                const n = self.pty.read(buf) catch |err| switch (err) {
                    error.WouldBlock => 0,
                    else => return err,
                };
                if (n == 0) {
                    // EOF => child exited / PTY closed.
                    break;
                }
                const data = buf[0..n];
                if (containsClearSeq(data)) {
                    self.backlog.clear();
                }
                self.backlog.append(data);
                if (self.client) |*client| {
                    pod_protocol.writeFrame(client, .output, data) catch {
                        client.close();
                        self.client = null;
                    };
                }
            }

            // Client input.
            // IMPORTANT: handle HUP/ERR first and ensure we never deref a client
            // after it has been closed in the same poll cycle.
            if (self.client != null and poll_fds[2].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                if (poll_fds[2].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    self.client.?.close();
                    self.client = null;
                } else if (poll_fds[2].revents & posix.POLL.IN != 0) {
                    const n = posix.read(self.client.?.fd, buf) catch |err| switch (err) {
                        error.WouldBlock => 0,
                        else => return err,
                    };
                    if (n == 0) {
                        self.client.?.close();
                        self.client = null;
                    } else {
                        const slice = buf[0..n];
                        self.reader.feed(slice, @ptrCast(self), podFrameCallback);
                    }
                }
            }
        }
    }

    fn handleFrame(self: *Pod, frame: pod_protocol.Frame) void {
        switch (frame.frame_type) {
            .input => {
                _ = self.pty.write(frame.payload) catch {};
            },
            .resize => {
                if (frame.payload.len >= 4) {
                    const cols = std.mem.readInt(u16, frame.payload[0..2], .big);
                    const rows = std.mem.readInt(u16, frame.payload[2..4], .big);
                    self.pty.setSize(cols, rows) catch {};
                }
            },
            else => {},
        }
    }

    /// Accept a VT client — replays backlog, then streams live output.
    fn acceptVtClient(self: *Pod, conn: core.IpcConnection, backlog_tmp: []u8) void {
        debugLog("acceptVtClient: fd={d} replacing={}", .{ conn.fd, self.client != null });
        // Replace existing client if any.
        if (self.client) |*old| old.close();

        setBlocking(conn.fd);
        self.client = conn;
        self.reader.reset();

        // Replay backlog.
        const n = self.backlog.copyOut(backlog_tmp);
        var off: usize = 0;
        while (off < n) {
            const chunk = @min(@as(usize, 16 * 1024), n - off);
            pod_protocol.writeFrame(&self.client.?, .output, backlog_tmp[off .. off + chunk]) catch {};
            off += chunk;
        }
        pod_protocol.writeFrame(&self.client.?, .backlog_end, &[_]u8{}) catch {};

        self.backlog.clear();
        self.pty_paused = false;
    }

    /// Handle a binary SHP control connection (channel ⑤).
    /// Reads one ShpShellEvent from SHP and forwards as binary shell_event on POD uplink.
    fn handleBinaryShpConnection(self: *Pod, conn: core.IpcConnection) void {
        debugLog("shp connection fd={d}", .{conn.fd});
        // Read the binary control header.
        const hdr = wire.readControlHeader(conn.fd) catch {
            var tmp = conn;
            tmp.close();
            return;
        };

        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (msg_type != .shp_shell_event or hdr.payload_len < @sizeOf(wire.ShpShellEvent)) {
            var tmp = conn;
            tmp.close();
            return;
        }

        // Read the fixed struct.
        const evt = wire.readStruct(wire.ShpShellEvent, conn.fd) catch {
            var tmp = conn;
            tmp.close();
            return;
        };

        // Read trailing variable data (cmd + cwd).
        var trail_buf: [8192]u8 = undefined;
        const trail_len: usize = @as(usize, evt.cmd_len) + @as(usize, evt.cwd_len);
        if (trail_len > trail_buf.len) {
            var tmp = conn;
            tmp.close();
            return;
        }
        if (trail_len > 0) {
            wire.readExact(conn.fd, trail_buf[0..trail_len]) catch {
                var tmp = conn;
                tmp.close();
                return;
            };
        }

        var tmp = conn;
        tmp.close();

        // Forward as binary shell_event on the POD uplink (channel ④).
        if (!self.uplink.ensureConnected()) return;
        const uplink_fd = self.uplink.fd orelse return;
        wire.writeControlWithTrail(uplink_fd, .shell_event, std.mem.asBytes(&evt), trail_buf[0..trail_len]) catch {
            self.uplink.disconnect();
        };
    }

    /// Handle auxiliary input connection (e.g., `hexe pod send`).
    /// Reads pod_protocol frames and writes input directly to the PTY
    /// without replacing the main VT client.
    fn handleAuxInput(self: *Pod, conn: core.IpcConnection) void {
        setBlocking(conn.fd);
        var buf: [4096]u8 = undefined;
        // Read available data and parse frames.
        const n = posix.read(conn.fd, &buf) catch {
            var tmp = conn;
            tmp.close();
            return;
        };
        if (n > 0) {
            // Parse pod_protocol frames from the data.
            var off: usize = 0;
            while (off + 5 <= n) {
                const frame_type_byte = buf[off];
                const payload_len = std.mem.readInt(u32, buf[off + 1 ..][0..4], .big);
                off += 5;
                if (payload_len > n - off) break;
                if (frame_type_byte == @intFromEnum(pod_protocol.FrameType.input)) {
                    _ = self.pty.write(buf[off .. off + payload_len]) catch {};
                } else if (frame_type_byte == @intFromEnum(pod_protocol.FrameType.resize)) {
                    if (payload_len >= 4) {
                        const cols = std.mem.readInt(u16, buf[off..][0..2], .big);
                        const rows = std.mem.readInt(u16, buf[off + 2 ..][0..2], .big);
                        self.pty.setSize(cols, rows) catch {};
                    }
                }
                off += payload_len;
            }
        }
        var tmp = conn;
        tmp.close();
    }

    fn lastOsc7Cwd(self: *Pod) ?[]const u8 {
        // We do not currently run a VT parser inside the pod process, so
        // we cannot extract OSC 7 cwd here. Keep the initial cwd (null).
        _ = self;
        return null;
    }
};

fn podFrameCallback(ctx: *anyopaque, frame: pod_protocol.Frame) void {
    const pod: *Pod = @ptrCast(@alignCast(ctx));
    pod.handleFrame(frame);
}

fn containsClearSeq(data: []const u8) bool {
    // Keep it simple for MVP: form-feed or CSI 3J.
    if (std.mem.indexOfScalar(u8, data, 0x0c) != null) return true;
    return std.mem.indexOf(u8, data, "\x1b[3J") != null;
}

test "ring buffer basic" {
    var buf: [8]u8 = undefined;
    var rb = RingBuffer{ .buf = &buf };
    rb.append("abcd");
    rb.append("ef");
    var out: [8]u8 = undefined;
    const n1 = rb.copyOut(&out);
    try std.testing.expectEqual(@as(usize, 6), n1);
    try std.testing.expect(std.mem.eql(u8, out[0..6], "abcdef"));

    rb.append("0123456789");
    const n2 = rb.copyOut(&out);
    try std.testing.expectEqual(@as(usize, 8), n2);
}
