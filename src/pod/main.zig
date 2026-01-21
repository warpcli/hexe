const std = @import("std");
const posix = std.posix;

const core = @import("core");
const pod_protocol = core.pod_protocol;

pub const PodArgs = struct {
    daemon: bool = true,
    uuid: []const u8,
    socket_path: []const u8,
    shell: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    debug: bool = false,
    log_file: ?[]const u8 = null,
    /// When true, print a single JSON line on stdout once ready.
    emit_ready: bool = false,
};

/// Run a per-pane pod process.
///
/// In normal operation pods are launched by `hexe-ses`.
pub fn run(args: PodArgs) !void {
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

    var pod = try Pod.init(allocator, args.uuid, args.socket_path, sh, args.cwd);
    defer pod.deinit();

    if (args.debug) {
        std.debug.print("[pod] started uuid={s} socket={s}\n", .{ args.uuid[0..@min(args.uuid.len, 8)], args.socket_path });
    }

    if (args.emit_ready) {
        // IMPORTANT: write handshake to stdout (ses reads stdout).
        const stdout = std.fs.File.stdout();
        var msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "{{\"type\":\"pod_ready\",\"uuid\":\"{s}\",\"pid\":{d}}}\n", .{ args.uuid, pod.pty.child_pid });
        try stdout.writeAll(msg);
    }

    try pod.run();
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

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        return .{ .buf = try allocator.alloc(u8, capacity) };
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

    pub fn init(allocator: std.mem.Allocator, uuid_str: []const u8, socket_path: []const u8, shell: []const u8, cwd: ?[]const u8) !Pod {
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const extra_env = [_][2][]const u8{.{ "HEXE_PANE_UUID", uuid_str }};
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
        if (self.client) |*c| {
            c.close();
        }
        self.server.deinit();
        self.pty.close();
        self.backlog.deinit(self.allocator);
        self.reader.deinit(self.allocator);
        self.input_reader.deinit(self.allocator);
    }

    pub fn run(self: *Pod) !void {
        var poll_fds: [3]posix.pollfd = undefined;
        var buf = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(buf);
        var backlog_tmp = try self.allocator.alloc(u8, pod_protocol.MAX_FRAME_LEN);
        defer self.allocator.free(backlog_tmp);

        while (true) {
            // Exit if the child shell/process exited.
            if (self.pty.pollStatus() != null) break;

            // server socket
            poll_fds[0] = .{ .fd = self.server.getFd(), .events = posix.POLL.IN, .revents = 0 };
            // pty
            poll_fds[1] = .{ .fd = self.pty.master_fd, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
            // client (optional)
            poll_fds[2] = .{ .fd = if (self.client) |c| c.fd else -1, .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };

            _ = posix.poll(&poll_fds, 1000) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };

            // Accept new connection.
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                if (self.server.tryAccept() catch null) |conn| {
                    if (self.client == null) {
                        // No existing client - this is the main mux connection
                        self.client = conn;
                        // Replay backlog.
                        const n = self.backlog.copyOut(backlog_tmp);
                        var off: usize = 0;
                        while (off < n) {
                            const chunk = @min(@as(usize, 16 * 1024), n - off);
                            pod_protocol.writeFrame(&self.client.?, .output, backlog_tmp[off .. off + chunk]) catch {};
                            off += chunk;
                        }
                        pod_protocol.writeFrame(&self.client.?, .backlog_end, &[_]u8{}) catch {};
                    } else {
                        // Already have a client - this is an input-only connection (e.g., hexe com send)
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
                if (self.client) |*c| {
                    pod_protocol.writeFrame(c, .output, data) catch {
                        c.close();
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
