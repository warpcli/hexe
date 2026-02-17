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
const xev = @import("xev").Dynamic;
const PodUplink = @import("uplink.zig").PodUplink;
const buffering = @import("buffering.zig");
const RingBuffer = buffering.RingBuffer;
const Osc7Scanner = buffering.Osc7Scanner;
const containsClearSeq = buffering.containsClearSeq;

var pod_debug: bool = false;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!pod_debug) return;
    std.debug.print("[pod] " ++ fmt ++ "\n", args);
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
    // Use page_allocator for log path since it must survive daemonization
    const log_path: ?[]const u8 = if (args.log_file) |path|
        (if (path.len > 0) path else null)
    else if (args.debug)
        (core.ipc.getLogPath(std.heap.page_allocator) catch null)
    else
        null;

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
    // Detect shell type from /proc/<child_pid>/comm
    const shell = detectShell(child_pid);

    var meta = try pod_meta.PodMeta.init(
        allocator,
        uuid,
        name,
        pod_pid,
        child_pid,
        cwd,
        shell,
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

fn detectShell(child_pid: posix.pid_t) ?[]const u8 {
    if (child_pid <= 0) return null;

    var comm_path_buf: [64]u8 = undefined;
    const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{child_pid}) catch return null;
    const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch return null;
    defer comm_file.close();

    var comm_buf: [64]u8 = undefined;
    const comm_len = comm_file.read(&comm_buf) catch return null;
    if (comm_len == 0) return null;

    const comm = std.mem.trim(u8, comm_buf[0..comm_len], " \t\n\r");
    if (comm.len == 0) return null;

    // Return known shell types
    if (std.mem.eql(u8, comm, "bash")) return "bash";
    if (std.mem.eql(u8, comm, "zsh")) return "zsh";
    if (std.mem.eql(u8, comm, "fish")) return "fish";
    if (std.mem.eql(u8, comm, "sh")) return "sh";
    if (std.mem.eql(u8, comm, "dash")) return "dash";
    if (std.mem.eql(u8, comm, "ksh")) return "ksh";
    if (std.mem.eql(u8, comm, "tcsh")) return "tcsh";
    if (std.mem.eql(u8, comm, "csh")) return "csh";
    if (std.mem.eql(u8, comm, "nu")) return "nushell";
    if (std.mem.eql(u8, comm, "pwsh")) return "powershell";
    if (std.mem.eql(u8, comm, "elvish")) return "elvish";
    if (std.mem.eql(u8, comm, "xonsh")) return "xonsh";
    if (std.mem.eql(u8, comm, "oil")) return "oil";

    return null;
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
    var tmp = try pod_meta.PodMeta.init(allocator, uuid, null, 0, 0, null, null, false, null, 0);
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

    // OSC 7 CWD tracking
    osc7_scanner: Osc7Scanner = .{},
    osc7_cwd: ?[]u8 = null,

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

        var backlog = try RingBuffer.init(allocator, core.wire.MAX_PAYLOAD_LEN);
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
        if (self.osc7_cwd) |cwd| self.allocator.free(cwd);
    }

    pub fn run(self: *Pod, opts: RunOptions) !void {
        try xev.detect();
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();

        const server_watcher = xev.File.initFd(self.server.getFd());
        const pty_watcher = xev.File.initFd(self.pty.master_fd);
        var server_completion: xev.Completion = .{};
        var pty_completion: xev.Completion = .{};
        var timer_completion: xev.Completion = .{};
        var ticker = try xev.Timer.init();
        defer ticker.deinit();

        const buf = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(buf);
        const backlog_tmp = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(backlog_tmp);

        var should_stop = false;
        var callback_error: ?anyerror = null;
        var pty_armed = false;
        var client_completions: [4]xev.Completion = .{ .{}, .{}, .{}, .{} };
        var client_slots: [4]ClientSlot = .{
            .{ .parent = undefined, .fd = -1 },
            .{ .parent = undefined, .fd = -1 },
            .{ .parent = undefined, .fd = -1 },
            .{ .parent = undefined, .fd = -1 },
        };
        var client_next_slot: usize = 0;

        var pty_ctx = PtyContext{
            .pod = self,
            .io_buf = buf,
            .loop = &loop,
            .watcher = pty_watcher,
            .completion = &pty_completion,
            .should_stop = &should_stop,
            .callback_error = &callback_error,
            .armed = &pty_armed,
        };

        var client_ctx = ClientContext{
            .pod = self,
            .io_buf = buf,
            .loop = &loop,
            .callback_error = &callback_error,
            .completions = &client_completions,
            .slots = &client_slots,
            .next_slot = &client_next_slot,
        };

        var accept_ctx = AcceptContext{
            .pod = self,
            .backlog_tmp = backlog_tmp,
            .pty_ctx = &pty_ctx,
            .client_ctx = &client_ctx,
        };
        server_watcher.poll(&loop, &server_completion, .read, AcceptContext, &accept_ctx, acceptCallback);
        armPtyWatcher(&pty_ctx);

        var timer_ctx = TimerContext{
            .pod = self,
            .opts = opts,
        };
        ticker.run(&loop, &timer_completion, 100, TimerContext, &timer_ctx, timerCallback);

        while (true) {
            // Exit if the child shell/process exited.
            if (self.pty.pollStatus() != null) break;

            if (should_stop) break;
            if (callback_error) |err| return err;

            try loop.run(.once);

            if (should_stop) break;
            if (callback_error) |err| return err;
        }
    }

    const AcceptContext = struct {
        pod: *Pod,
        backlog_tmp: []u8,
        pty_ctx: *PtyContext,
        client_ctx: *ClientContext,
    };

    const PtyContext = struct {
        pod: *Pod,
        io_buf: []u8,
        loop: *xev.Loop,
        watcher: xev.File,
        completion: *xev.Completion,
        should_stop: *bool,
        callback_error: *?anyerror,
        armed: *bool,
    };

    const ClientSlot = struct {
        parent: *ClientContext,
        fd: posix.fd_t,
    };

    const ClientContext = struct {
        pod: *Pod,
        io_buf: []u8,
        loop: *xev.Loop,
        callback_error: *?anyerror,
        completions: *[4]xev.Completion,
        slots: *[4]ClientSlot,
        next_slot: *usize,
    };

    const TimerContext = struct {
        pod: *Pod,
        opts: RunOptions,
        last_meta_ms: i64 = 0,
    };

    fn acceptCallback(
        ctx: ?*AcceptContext,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const accept_ctx = ctx orelse return .disarm;
        _ = result catch return .rearm;

        while (accept_ctx.pod.server.tryAccept() catch null) |conn| {
            accept_ctx.pod.handleAcceptedConnection(conn, accept_ctx.backlog_tmp);
            if (accept_ctx.pod.client) |client| {
                armClientWatcher(accept_ctx.client_ctx, client.fd);
            }
            if (accept_ctx.pod.client != null and accept_ctx.pod.pty_paused) {
                accept_ctx.pod.pty_paused = false;
                armPtyWatcher(accept_ctx.pty_ctx);
            }
        }

        return .rearm;
    }

    fn armClientWatcher(ctx: *ClientContext, client_fd: posix.fd_t) void {
        const slot = ctx.next_slot.* % ctx.completions.len;
        ctx.next_slot.* += 1;

        ctx.slots[slot] = .{ .parent = ctx, .fd = client_fd };
        const watcher = xev.File.initFd(client_fd);
        const completion = &ctx.completions[slot];
        completion.* = .{};
        watcher.poll(ctx.loop, completion, .read, ClientSlot, &ctx.slots[slot], clientCallback);
    }

    fn clientCallback(
        ctx: ?*ClientSlot,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const slot = ctx orelse return .disarm;
        const client_ctx = slot.parent;
        _ = result catch return .disarm;

        const current = client_ctx.pod.client orelse return .disarm;
        if (current.fd != slot.fd) return .disarm;

        const n = posix.read(slot.fd, client_ctx.io_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => {
                client_ctx.callback_error.* = err;
                return .disarm;
            },
        };

        if (n == 0) {
            if (client_ctx.pod.client) |*conn| conn.close();
            client_ctx.pod.client = null;
            return .disarm;
        }

        client_ctx.pod.reader.feed(client_ctx.io_buf[0..n], @ptrCast(client_ctx.pod), podFrameCallback);
        return .rearm;
    }

    fn armPtyWatcher(ctx: *PtyContext) void {
        if (ctx.armed.* or ctx.pod.pty_paused) return;
        ctx.watcher.poll(ctx.loop, ctx.completion, .read, PtyContext, ctx, ptyCallback);
        ctx.armed.* = true;
    }

    fn ptyCallback(
        ctx: ?*PtyContext,
        _: *xev.Loop,
        _: *xev.Completion,
        _: xev.File,
        result: xev.PollError!xev.PollEvent,
    ) xev.CallbackAction {
        const pty_ctx = ctx orelse return .disarm;
        _ = result catch {
            pty_ctx.armed.* = false;
            pty_ctx.should_stop.* = true;
            return .disarm;
        };

        if (pty_ctx.pod.client == null) {
            const free = pty_ctx.pod.backlog.available();
            if (free == 0) {
                pty_ctx.pod.pty_paused = true;
                pty_ctx.armed.* = false;
                return .disarm;
            }

            const read_buf = pty_ctx.io_buf[0..@min(pty_ctx.io_buf.len, free)];
            const n = pty_ctx.pod.pty.read(read_buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => {
                    pty_ctx.callback_error.* = err;
                    pty_ctx.armed.* = false;
                    return .disarm;
                },
            };

            if (n == 0) {
                pty_ctx.should_stop.* = true;
                pty_ctx.armed.* = false;
                return .disarm;
            }

            const data = read_buf[0..n];
            pty_ctx.pod.scanOsc7(data);
            if (containsClearSeq(data)) {
                pty_ctx.pod.backlog.clear();
            }
            if (!pty_ctx.pod.backlog.appendNoDrop(data) or pty_ctx.pod.backlog.isFull()) {
                pty_ctx.pod.pty_paused = true;
                pty_ctx.armed.* = false;
                return .disarm;
            }

            return .rearm;
        }

        const n = pty_ctx.pod.pty.read(pty_ctx.io_buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => {
                pty_ctx.callback_error.* = err;
                pty_ctx.armed.* = false;
                return .disarm;
            },
        };
        if (n == 0) {
            pty_ctx.should_stop.* = true;
            pty_ctx.armed.* = false;
            return .disarm;
        }

        const data = pty_ctx.io_buf[0..n];
        pty_ctx.pod.scanOsc7(data);
        if (containsClearSeq(data)) {
            pty_ctx.pod.backlog.clear();
        }
        pty_ctx.pod.backlog.append(data);
        if (pty_ctx.pod.client) |*client| {
            pod_protocol.writeFrame(client, .output, data) catch {
                client.close();
                pty_ctx.pod.client = null;
            };
        }

        return .rearm;
    }

    fn timerCallback(
        ctx: ?*TimerContext,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const timer_ctx = ctx orelse return .disarm;
        _ = result catch return .rearm;

        timer_ctx.pod.uplink.tick(timer_ctx.pod.pty.child_pid);

        if (timer_ctx.opts.write_meta) {
            const now_ms: i64 = std.time.milliTimestamp();
            if (now_ms - timer_ctx.last_meta_ms >= 1000) {
                const live_cwd = timer_ctx.pod.lastOsc7Cwd();
                writePodMetaSidecar(
                    timer_ctx.pod.allocator,
                    timer_ctx.pod.uuid[0..],
                    timer_ctx.opts.name,
                    live_cwd,
                    timer_ctx.opts.labels,
                    @intCast(c.getpid()),
                    timer_ctx.pod.pty.child_pid,
                    timer_ctx.opts.created_at,
                ) catch {};
                timer_ctx.last_meta_ms = now_ms;
            }
        }

        return .rearm;
    }

    fn handleAcceptedConnection(self: *Pod, conn: core.IpcConnection, backlog_tmp: []u8) void {
        if (!verifyPeerCredentials(conn.fd)) {
            var tmp = conn;
            tmp.close();
            return;
        }

        var handshake: [2]u8 = undefined;
        var hoff: usize = 0;
        while (hoff < 2) {
            const n = posix.read(conn.fd, handshake[hoff..]) catch {
                var tmp_conn = conn;
                tmp_conn.close();
                return;
            };
            if (n == 0) {
                var tmp_conn = conn;
                tmp_conn.close();
                return;
            }
            hoff += n;
        }

        if (handshake[1] != wire.PROTOCOL_VERSION) {
            debugLog("reject: unsupported protocol version {d} fd={d}", .{ handshake[1], conn.fd });
            var tmp_conn = conn;
            tmp_conn.close();
            return;
        }

        if (handshake[0] == wire.POD_HANDSHAKE_SES_VT) {
            debugLog("accept: SES VT client fd={d}", .{conn.fd});
            self.acceptVtClient(conn, backlog_tmp);
        } else if (handshake[0] == wire.POD_HANDSHAKE_SHP_CTL) {
            debugLog("accept: SHP ctl fd={d}", .{conn.fd});
            self.handleBinaryShpConnection(conn);
        } else if (handshake[0] == wire.POD_HANDSHAKE_AUX_INPUT) {
            debugLog("accept: aux input fd={d}", .{conn.fd});
            self.handleAuxInput(conn);
        } else {
            debugLog("accept: unknown handshake 0x{x:0>2} fd={d}", .{ handshake[0], conn.fd });
            var tmp_conn = conn;
            tmp_conn.close();
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

        // Send acknowledgment so client knows we're ready.
        wire.writeControl(conn.fd, .ok, &.{}) catch {
            debugLog("acceptVtClient: failed to send ack, closing fd={d}", .{conn.fd});
            var tmp = conn;
            tmp.close();
            self.client = null;
            return;
        };
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
        return self.osc7_cwd;
    }

    fn scanOsc7(self: *Pod, data: []const u8) void {
        var new_cwd: ?[]const u8 = null;
        self.osc7_scanner.feed(data, &new_cwd);
        if (new_cwd) |path| {
            // Store a copy of the path
            if (self.osc7_cwd) |old| self.allocator.free(old);
            self.osc7_cwd = self.allocator.dupe(u8, path) catch null;
        }
    }
};

fn podFrameCallback(ctx: *anyopaque, frame: pod_protocol.Frame) void {
    const pod: *Pod = @ptrCast(@alignCast(ctx));
    pod.handleFrame(frame);
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
