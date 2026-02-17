const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const xev = @import("xev").Dynamic;
const tty = @import("tty.zig");
const shared = @import("shared.zig");

const print = std.debug.print;

const AttachContext = struct {
    conn: *ipc.Connection,
    frame_reader: *pod_protocol.Reader,
    detach_code: u8,
    saw_prefix: bool = false,
    running: bool = true,
    net_buf: [4096]u8 = undefined,
    in_buf: [4096]u8 = undefined,
};

fn stdinCallback(
    ctx: ?*AttachContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const c = ctx orelse return .disarm;
    _ = result catch {
        c.running = false;
        return .disarm;
    };

    const n = std.posix.read(std.posix.STDIN_FILENO, &c.in_buf) catch {
        c.running = false;
        return .disarm;
    };
    if (n == 0) {
        c.running = false;
        return .disarm;
    }

    if (n == 1) {
        if (c.saw_prefix) {
            c.saw_prefix = false;
            if (c.in_buf[0] == 'd' or c.in_buf[0] == 'D') {
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
                c.running = false;
                return .disarm;
            }
            var tmp: [2]u8 = .{ c.detach_code, c.in_buf[0] };
            pod_protocol.writeFrame(c.conn, .input, tmp[0..2]) catch {
                c.running = false;
                return .disarm;
            };
            return .rearm;
        }
        if (c.in_buf[0] == c.detach_code) {
            c.saw_prefix = true;
            return .rearm;
        }
    }

    pod_protocol.writeFrame(c.conn, .input, c.in_buf[0..n]) catch {
        c.running = false;
        return .disarm;
    };
    return .rearm;
}

fn connCallback(
    ctx: ?*AttachContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const c = ctx orelse return .disarm;
    _ = result catch {
        c.running = false;
        return .disarm;
    };

    const n = std.posix.read(c.conn.fd, &c.net_buf) catch |err| switch (err) {
        error.WouldBlock => 0,
        else => {
            c.running = false;
            return .disarm;
        },
    };
    if (n == 0) {
        c.running = false;
        return .disarm;
    }

    c.frame_reader.feed(c.net_buf[0..n], @ptrCast(@alignCast(c.conn)), podFrameCallback);
    return .rearm;
}

const ResizeContext = struct {
    conn: *ipc.Connection,
    pipe_fd: std.posix.fd_t,
    net_buf: [4096]u8 = undefined,
};

fn resizeCallback(
    ctx: ?*ResizeContext,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const c = ctx orelse return .disarm;
    _ = result catch return .disarm;
    _ = std.posix.read(c.pipe_fd, &c.net_buf) catch 0;
    sendResize(c.conn, tty.getTermSize()) catch {};
    return .rearm;
}

pub fn runPodAttach(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    detach_key: []const u8,
) !void {
    const target_socket = try resolveTargetSocket(allocator, uuid, name, socket_path);
    defer allocator.free(target_socket);

    var client = ipc.Client.connect(target_socket) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("pod is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    // Send versioned handshake to identify as VT client.
    wire.sendHandshake(client.fd, wire.POD_HANDSHAKE_SES_VT) catch return;

    var conn = client.toConnection();

    // Enter raw mode on stdin so we can proxy bytes.
    const orig_termios = tty.enableRawMode(std.posix.STDIN_FILENO) catch null;
    defer if (orig_termios) |t| tty.disableRawMode(std.posix.STDIN_FILENO, t) catch {};

    // Initial resize.
    sendResize(&conn, tty.getTermSize()) catch {};

    // Winch handling via a self-pipe.
    var pipe_fds: [2]std.posix.fd_t = .{ -1, -1 };
    if (std.posix.pipe() catch null) |fds| {
        pipe_fds = fds;
    }
    defer {
        if (pipe_fds[0] >= 0) std.posix.close(pipe_fds[0]);
        if (pipe_fds[1] >= 0) std.posix.close(pipe_fds[1]);
    }

    const builtin = @import("builtin");
    if (pipe_fds[1] >= 0 and builtin.os.tag == .linux) {
        const c = @cImport({
            @cInclude("signal.h");
            @cInclude("unistd.h");
        });
        // Global-ish through a comptime static.
        WinchPipe.write_fd = pipe_fds[1];
        _ = c.signal(c.SIGWINCH, winchHandler);
    }

    // Detach sequence (tmux-ish): prefix Ctrl+<key> (default b), then 'd'.
    const det = if (detach_key.len == 1) detach_key[0] else 'b';
    const det_code: u8 = if (det >= 'a' and det <= 'z') det - 'a' + 1 else if (det >= 'A' and det <= 'Z') det - 'A' + 1 else 0x02;

    var frame_reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
    defer frame_reader.deinit(allocator);

    try xev.detect();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var attach_ctx = AttachContext{
        .conn = &conn,
        .frame_reader = &frame_reader,
        .detach_code = det_code,
    };

    var stdin_completion: xev.Completion = .{};
    var conn_completion: xev.Completion = .{};
    const stdin_watcher = xev.File.initFd(std.posix.STDIN_FILENO);
    const conn_watcher = xev.File.initFd(conn.fd);
    stdin_watcher.poll(&loop, &stdin_completion, .read, AttachContext, &attach_ctx, stdinCallback);
    conn_watcher.poll(&loop, &conn_completion, .read, AttachContext, &attach_ctx, connCallback);

    var resize_completion: xev.Completion = .{};
    var resize_ctx: ResizeContext = undefined;
    if (pipe_fds[0] >= 0) {
        resize_ctx = .{ .conn = &conn, .pipe_fd = pipe_fds[0] };
        const resize_watcher = xev.File.initFd(pipe_fds[0]);
        resize_watcher.poll(&loop, &resize_completion, .read, ResizeContext, &resize_ctx, resizeCallback);
    }

    while (attach_ctx.running) {
        try loop.run(.once);
    }
}

const WinchPipe = struct {
    pub var write_fd: std.posix.fd_t = -1;
};

fn winchHandler(_: i32) callconv(.c) void {
    if (WinchPipe.write_fd < 0) return;
    const c = @cImport({
        @cInclude("unistd.h");
    });
    var b: [1]u8 = .{0};
    _ = c.write(WinchPipe.write_fd, &b, 1);
}

fn sendResize(conn: *ipc.Connection, size: tty.TermSize) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], size.cols, .big);
    std.mem.writeInt(u16, payload[2..4], size.rows, .big);
    try pod_protocol.writeFrame(conn, .resize, &payload);
}

fn podFrameCallback(ctx: *anyopaque, frame: pod_protocol.Frame) void {
    const conn: *ipc.Connection = @ptrCast(@alignCast(ctx));
    _ = conn;
    switch (frame.frame_type) {
        .output => {
            _ = std.posix.write(std.posix.STDOUT_FILENO, frame.payload) catch {};
        },
        .backlog_end => {},
        else => {},
    }
}

fn resolveTargetSocket(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, socket_path: []const u8) ![]const u8 {
    // Reuse the same resolution strategy as pod_send.
    // Keep this local to avoid circular imports in commands.
    if (socket_path.len > 0) {
        return allocator.dupe(u8, socket_path);
    }
    if (uuid.len > 0) {
        if (uuid.len != 32) {
            print("Error: --uuid must be 32 hex chars\n", .{});
            return error.InvalidUuid;
        }
        return ipc.getPodSocketPath(allocator, uuid);
    }
    if (name.len > 0) {
        // Prefer exact-name match in .meta (newest created_at).
        const dir = try ipc.getSocketDir(allocator);
        defer allocator.free(dir);

        var best_uuid: ?[32]u8 = null;
        var best_created_at: i64 = -1;

        var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "pod-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

            var f = d.openFile(entry.name, .{}) catch continue;
            defer f.close();
            var buf: [4096]u8 = undefined;
            const n = f.readAll(&buf) catch continue;
            if (n == 0) continue;
            const line = std.mem.trim(u8, buf[0..n], " \t\n\r");
            if (!std.mem.startsWith(u8, line, core.pod_meta.POD_META_PREFIX)) continue;

            const name_val = parseField(line, "name") orelse continue;
            if (!std.mem.eql(u8, name_val, name)) continue;
            const u = parseField(line, "uuid") orelse continue;
            if (u.len != 32) continue;
            const ca = parseField(line, "created_at") orelse "0";
            const created_at = std.fmt.parseInt(i64, ca, 10) catch 0;
            if (created_at >= best_created_at) {
                var uu: [32]u8 = undefined;
                @memcpy(&uu, u[0..32]);
                best_uuid = uu;
                best_created_at = created_at;
            }
        }

        if (best_uuid) |bu| {
            return ipc.getPodSocketPath(allocator, &bu);
        }

        // Fall back to alias pod@<name>.sock
        return core.pod_meta.PodMeta.aliasSocketPath(allocator, name);
    }

    print("Error: must provide --socket, --uuid, or --name\n", .{});
    return error.MissingTarget;
}

const parseField = shared.parseField;
