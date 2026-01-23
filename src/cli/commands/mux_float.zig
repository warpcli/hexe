const std = @import("std");
const core = @import("core");
const ipc = core.ipc;

const print = std.debug.print;

pub fn runMuxFloat(
    allocator: std.mem.Allocator,
    mux_uuid: []const u8,
    command: []const u8,
    title: []const u8,
    cwd: []const u8,
    result_file: []const u8,
    pass_env: bool,
    extra_env: []const u8,
    isolated: bool,
) !void {
    if (command.len == 0) {
        print("Error: --command is required\n", .{});
        return;
    }

    var socket_path_buf: ?[]const u8 = null;
    if (mux_uuid.len > 0) {
        socket_path_buf = try ipc.getMuxSocketPath(allocator, mux_uuid);
    } else {
        socket_path_buf = std.posix.getenv("HEXE_MUX_SOCKET");
    }

    const socket_path = socket_path_buf orelse {
        print("Error: --uuid required (or run inside hexe mux)\n", .{});
        return;
    };
    defer if (mux_uuid.len > 0) allocator.free(socket_path);

    var env_file_path: ?[]u8 = null;
    defer if (env_file_path) |path| allocator.free(path);
    if (pass_env) {
        const tmp_uuid = ipc.generateUuid();
        env_file_path = std.fmt.allocPrint(allocator, "/tmp/hexe-float-env-{s}.env", .{tmp_uuid}) catch null;
        if (env_file_path) |path| {
            const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
            if (file) |env_file| {
                defer env_file.close();
                var env_map = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
                defer env_map.deinit();
                var it = env_map.iterator();
                while (it.next()) |entry| {
                    env_file.writeAll(entry.key_ptr.*) catch {};
                    env_file.writeAll("=") catch {};
                    env_file.writeAll(entry.value_ptr.*) catch {};
                    env_file.writeAll("\n") catch {};
                }
            }
        }
    }

    var client = tryConnectMux(allocator, mux_uuid, socket_path) orelse {
        print("mux is not running\n", .{});
        return;
    };
    defer client.close();

    var extra_env_json: std.ArrayList(u8) = .empty;
    defer extra_env_json.deinit(allocator);
    if (extra_env.len > 0) {
        var w = extra_env_json.writer(allocator);
        try w.writeAll("[");
        var it = std.mem.splitScalar(u8, extra_env, ',');
        var first = true;
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " ");
            if (trimmed.len == 0) continue;
            if (!first) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(w, trimmed);
            try w.writeAll("\"");
            first = false;
        }
        try w.writeAll("]");
    }

    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(allocator);
    var writer = msg_buf.writer(allocator);
    try writer.writeAll("{\"type\":\"float\",\"wait\":true");
    try writer.writeAll(",\"command\":\"");
    try writeJsonEscaped(writer, command);
    try writer.writeAll("\"");
    if (title.len > 0) {
        try writer.writeAll(",\"title\":\"");
        try writeJsonEscaped(writer, title);
        try writer.writeAll("\"");
    }
    if (cwd.len > 0) {
        try writer.writeAll(",\"cwd\":\"");
        try writeJsonEscaped(writer, cwd);
        try writer.writeAll("\"");
    }
    if (result_file.len > 0) {
        try writer.writeAll(",\"result_file\":\"");
        try writeJsonEscaped(writer, result_file);
        try writer.writeAll("\"");
    }
    if (env_file_path) |path| {
        try writer.writeAll(",\"env_file\":\"");
        try writeJsonEscaped(writer, path);
        try writer.writeAll("\"");
    }
    if (extra_env_json.items.len > 0) {
        try writer.print(",\"extra_env\":{s}", .{extra_env_json.items});
    }
    if (isolated) {
        try writer.writeAll(",\"isolated\":true");
    }
    try writer.writeAll("}");

    var conn = client.toConnection();
    conn.sendLine(msg_buf.items) catch |err| {
        print("Error: {s}\n", .{@errorName(err)});
        return;
    };

    var resp_buf: [65536]u8 = undefined;
    const response = conn.recvLine(&resp_buf) catch null;
    if (response == null) {
        print("No response from mux\n", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.?, .{}) catch {
        print("Invalid response from mux\n", .{});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("type")) |t| {
        if (std.mem.eql(u8, t.string, "float_result")) {
            const stdout_content = if (root.get("stdout")) |v| v.string else "";
            if (stdout_content.len > 0) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, stdout_content) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
            }
            const exit_code: u8 = if (root.get("exit_code")) |v| @intCast(@max(@as(i64, 0), v.integer)) else 0;
            std.process.exit(exit_code);
        }
        if (std.mem.eql(u8, t.string, "error")) {
            if (root.get("message")) |m| {
                print("Error: {s}\n", .{m.string});
            }
            return;
        }
    }

    print("Unexpected response from mux\n", .{});
}

fn tryConnectMux(allocator: std.mem.Allocator, mux_uuid: []const u8, socket_path: []const u8) ?ipc.Client {
    const client = ipc.Client.connect(socket_path) catch |err| {
        if (err != error.ConnectionRefused and err != error.FileNotFound) return null;
        // If explicit uuid was provided, do not guess.
        if (mux_uuid.len > 0) return null;

        // Stale HEXE_MUX_SOCKET is common when a pod survives a mux restart.
        const resolved = resolveMuxSocketViaSes(allocator) orelse return null;
        defer allocator.free(resolved);
        return ipc.Client.connect(resolved) catch return null;
    };
    return client;
}

fn resolveMuxSocketViaSes(allocator: std.mem.Allocator) ?[]u8 {
    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse return null;
    if (pane_uuid.len != 32) return null;

    const ses_socket = ipc.getSesSocketPath(allocator) catch return null;
    defer allocator.free(ses_socket);

    var client = ipc.Client.connect(ses_socket) catch return null;
    defer client.close();
    var conn = client.toConnection();

    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{pane_uuid}) catch return null;
    conn.sendLine(req) catch return null;

    var resp_buf: [4096]u8 = undefined;
    const line = conn.recvLine(&resp_buf) catch return null;
    if (line == null) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line.?, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value.object;
    const sid = if (root.get("session_id")) |v|
        if (v == .string) v.string else ""
    else if (root.get("detached_session_id")) |v|
        if (v == .string) v.string else ""
    else
        "";

    if (sid.len != 32) return null;
    const mux_socket = ipc.getMuxSocketPath(allocator, sid) catch return null;
    return @constCast(mux_socket);
}

fn writeJsonEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}
