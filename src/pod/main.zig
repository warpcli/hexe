const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const core = @import("core");
const pod_protocol = core.pod_protocol;
const pod_meta = core.pod_meta;

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
    const default_log: []const u8 = "/tmp/hexe-pod-debug.log";
    const log_path = if (args.log_file) |path| if (path.len > 0) path else null else if (args.debug) default_log else null;

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
        writePodMetaSidecar(allocator, args.uuid, args.name, args.cwd, args.labels, @intCast(c.getpid()), pod.pty.child_pid, created_at) catch {};
    }

    var created_alias_path: ?[]const u8 = null;
    defer if (created_alias_path) |p| allocator.free(p);

    // Optional: create alias symlink pod@<name>.sock -> pod-<uuid>.sock
    if (args.write_alias and args.name != null and args.name.?.len > 0) {
        created_alias_path = createAliasSymlink(allocator, args.name.?, args.socket_path) catch null;
    }

    if (args.debug) {
        if (args.name) |n| {
            std.debug.print("[pod] started uuid={s} name={s} socket={s}\n", .{ args.uuid[0..@min(args.uuid.len, 8)], n, args.socket_path });
        } else {
            std.debug.print("[pod] started uuid={s} socket={s}\n", .{ args.uuid[0..@min(args.uuid.len, 8)], args.socket_path });
        }
    }

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
        deletePodMetaSidecar(allocator, args.uuid) catch {};
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
    input_reader: pod_protocol.Reader,
    pty_paused: bool = false,

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
        };
        var pty = try core.Pty.spawnWithEnv(shell, cwd, &extra_env);
        errdefer pty.close();

        var server = try core.ipc.Server.init(allocator, socket_path);
        errdefer server.deinit();

        var backlog = try RingBuffer.init(allocator, 4 * 1024 * 1024);
        errdefer backlog.deinit(allocator);

        var reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
        errdefer reader.deinit(allocator);

        var input_reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
        errdefer input_reader.deinit(allocator);

        return .{
            .allocator = allocator,
            .uuid = uuid,
            .pty = pty,
            .server = server,
            .backlog = backlog,
            .reader = reader,
            .input_reader = input_reader,
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
        self.input_reader.deinit(self.allocator);
    }

    pub fn run(self: *Pod, opts: RunOptions) !void {
        var poll_fds: [3]posix.pollfd = undefined;
        var buf = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(buf);
        var backlog_tmp = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(backlog_tmp);

        var last_meta_ms: i64 = 0;

        while (true) {
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
                    if (self.client == null) {
                        // No existing client - this is the main mux connection
                        // IMPORTANT: core.ipc.Server.tryAccept accepts with SOCK_NONBLOCK,
                        // which makes the accepted client fd non-blocking. Under heavy
                        // output, writes can return WouldBlock and we would otherwise
                        // close the mux connection, making the mux think the pane died.
                        //
                        // For the main mux connection we want blocking semantics.
                        setBlocking(conn.fd);
                        self.client = conn;

                        // Reset the frame reader to discard any partial state left
                        // from the previous connection. Without this, a new mux's
                        // input frames get misinterpreted as continuations of the
                        // old connection's partial frames, causing commands to hang.
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

                        // Backlog has been delivered. Clear it so we can resume
                        // capturing new output without dropping.
                        self.backlog.clear();
                        self.pty_paused = false;
                    } else {
                        // Already have a client - this is an input-only connection (e.g., hexe mux send)
                        // Read any input frames and process them, then close
                        var input_buf: [4096]u8 = undefined;
                        const n = posix.read(conn.fd, &input_buf) catch 0;
                        if (n > 0) {
                            self.input_reader.reset();
                            self.input_reader.feed(input_buf[0..n], @ptrCast(self), podFrameCallback);
                        }
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
