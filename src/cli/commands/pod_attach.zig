const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const tty = @import("tty.zig");
const shared = @import("shared.zig");


const print = std.debug.print;


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

    // Send handshake byte to identify as VT client.
    const handshake = [_]u8{wire.POD_HANDSHAKE_SES_VT};
    wire.writeAll(client.fd, &handshake) catch return;

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
    var saw_prefix: bool = false;

    var frame_reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
    defer frame_reader.deinit(allocator);

    var poll_fds: [3]std.posix.pollfd = undefined;
    var in_buf: [4096]u8 = undefined;
    var net_buf: [4096]u8 = undefined;

    while (true) {
        poll_fds[0] = .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 };
        poll_fds[1] = .{ .fd = conn.fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 };
        poll_fds[2] = .{ .fd = if (pipe_fds[0] >= 0) pipe_fds[0] else -1, .events = std.posix.POLL.IN, .revents = 0 };

        _ = std.posix.poll(&poll_fds, 250) catch |err| {
            if (err == error.Interrupted) continue;
            return err;
        };

        // Resize signal.
        if (pipe_fds[0] >= 0 and poll_fds[2].revents & std.posix.POLL.IN != 0) {
            _ = std.posix.read(pipe_fds[0], &net_buf) catch 0;
            sendResize(&conn, tty.getTermSize()) catch {};
        }

        // Remote output.
        if (poll_fds[1].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            break;
        }
        if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(conn.fd, &net_buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0) break;
            frame_reader.feed(net_buf[0..n], @ptrCast(@alignCast(&conn)), podFrameCallback);
        }

        // Local input.
        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &in_buf) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            if (n == 0) break;

            // Detach check:
            // - press Ctrl+<key> (prefix)
            // - then press 'd'
            if (n == 1) {
                if (saw_prefix) {
                    saw_prefix = false;
                    if (in_buf[0] == 'd' or in_buf[0] == 'D') {
                        _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
                        break;
                    }
                    // Not detach: forward both prefix and this byte.
                    var tmp: [2]u8 = .{ det_code, in_buf[0] };
                    try pod_protocol.writeFrame(&conn, .input, tmp[0..2]);
                    continue;
                }
                if (in_buf[0] == det_code) {
                    saw_prefix = true;
                    continue;
                }
            }

            try pod_protocol.writeFrame(&conn, .input, in_buf[0..n]);
        }
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
