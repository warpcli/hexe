const std = @import("std");
const ipc = @import("ipc.zig");
const wire = @import("wire.zig");
const frontend_client = @import("frontend_client.zig");

pub fn localIpcTransport(socket_path: ?[]const u8, autostart_ses: bool) frontend_client.Transport {
    return .{ .local_ipc = .{
        .autostart_ses = autostart_ses,
        .socket_path = socket_path,
    } };
}

pub fn sendNotify(
    allocator: std.mem.Allocator,
    transport: frontend_client.Transport,
    message: []const u8,
) !void {
    switch (transport) {
        .local_ipc => |cfg| {
            var owned_socket_path: ?[]const u8 = null;
            defer if (owned_socket_path) |path| allocator.free(path);

            const socket_path = if (cfg.socket_path) |path|
                path
            else blk: {
                owned_socket_path = try ipc.getSesSocketPath(allocator);
                break :blk owned_socket_path.?;
            };

            var client = try ipc.Client.connect(socket_path);
            defer client.close();

            try wire.sendHandshake(client.fd, wire.SES_HANDSHAKE_CLI);
            const notify = wire.Notify{ .msg_len = @intCast(message.len) };
            try wire.writeControlWithTrail(client.fd, .notify, std.mem.asBytes(&notify), message);
        },
    }
}
