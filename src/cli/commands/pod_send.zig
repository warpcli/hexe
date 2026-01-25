const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const pod_meta = core.pod_meta;
const shared = @import("shared.zig");

const print = std.debug.print;

pub fn runPodSend(
    allocator: std.mem.Allocator,
    uuid: []const u8,
    name: []const u8,
    socket_path: []const u8,
    enter: bool,
    ctrl: []const u8,
    text: []const u8,
) !void {
    // Build bytes to send.
    var data_buf: [4096]u8 = undefined;
    var data_len: usize = 0;

    if (ctrl.len > 0) {
        if (ctrl.len == 1 and ((ctrl[0] >= 'a' and ctrl[0] <= 'z') or (ctrl[0] >= 'A' and ctrl[0] <= 'Z'))) {
            const cch: u8 = if (ctrl[0] >= 'a' and ctrl[0] <= 'z') ctrl[0] else (ctrl[0] - 'A' + 'a');
            data_buf[0] = cch - 'a' + 1;
            data_len = 1;
        } else {
            print("Error: --ctrl requires a single letter (a-z)\n", .{});
            return;
        }
    } else if (text.len > 0) {
        if (text.len > data_buf.len - 1) {
            print("Error: text too long\n", .{});
            return;
        }
        @memcpy(data_buf[0..text.len], text);
        data_len = text.len;
    }

    if (enter and data_len < data_buf.len) {
        data_buf[data_len] = '\n';
        data_len += 1;
    }

    if (data_len == 0) {
        print("Error: no data to send (use text argument, --ctrl, or --enter)\n", .{});
        return;
    }

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

    // Send handshake byte for auxiliary input.
    const handshake = [_]u8{wire.POD_HANDSHAKE_AUX_INPUT};
    wire.writeAll(client.fd, &handshake) catch return;

    var conn = client.toConnection();
    try pod_protocol.writeFrame(&conn, .input, data_buf[0..data_len]);
}

fn resolveTargetSocket(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, socket_path: []const u8) ![]const u8 {
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
        // Resolve by scanning .meta and picking the newest matching name.
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
            if (!std.mem.startsWith(u8, line, pod_meta.POD_META_PREFIX)) continue;

            // Cheap parse: look for " name=<name>" and uuid/created_at.
            if (!metaLineNameEquals(line, name)) continue;
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

        // Fall back to alias path pod@<name>.sock.
        return pod_meta.PodMeta.aliasSocketPath(allocator, name);
    }

    print("Error: must provide --socket, --uuid, or --name\n", .{});
    return error.MissingTarget;
}

fn metaLineNameEquals(line: []const u8, expected: []const u8) bool {
    const name_val = parseField(line, "name") orelse return false;
    return std.mem.eql(u8, name_val, expected);
}

const parseField = shared.parseField;
