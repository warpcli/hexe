const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_protocol = core.pod_protocol;
const state = @import("../state.zig");

/// Handle send_keys request - sends keystrokes to a pane via its pod
pub fn handleSendKeys(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    // Get hex-encoded data
    const data_hex = (root.get("hex") orelse return sendError(conn, "missing_hex")).string;

    // Decode hex
    if (data_hex.len % 2 != 0) {
        return sendError(conn, "invalid_hex");
    }
    const data_len = data_hex.len / 2;
    if (data_len > 4096) {
        return sendError(conn, "data_too_large");
    }
    var data_buf: [4096]u8 = undefined;
    _ = std.fmt.hexToBytes(data_buf[0..data_len], data_hex) catch {
        return sendError(conn, "invalid_hex");
    };
    const data = data_buf[0..data_len];

    // Check if broadcast
    const broadcast = if (root.get("broadcast")) |b| b.bool else false;

    if (broadcast) {
        // Send to all attached panes
        var iter = ses_state.panes.valueIterator();
        while (iter.next()) |pane| {
            if (pane.state == .attached) {
                sendToPod(pane.pod_socket_path, data) catch continue;
            }
        }
        try conn.sendLine("{\"type\":\"ok\"}");
    } else {
        // Send to specific pane
        const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
        if (uuid_str.len != 32) {
            return sendError(conn, "invalid_uuid");
        }

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const pane = ses_state.panes.get(uuid) orelse {
            try conn.sendLine("{\"type\":\"not_found\"}");
            return;
        };

        sendToPod(pane.pod_socket_path, data) catch {
            return sendError(conn, "pod_send_failed");
        };

        try conn.sendLine("{\"type\":\"ok\"}");
    }
}

/// Send input data to a pod via its socket
fn sendToPod(pod_socket_path: []const u8, data: []const u8) !void {
    // Connect to pod socket
    var pod_client = try ipc.Client.connect(pod_socket_path);
    defer pod_client.close();

    var pod_conn = pod_client.toConnection();

    // Send input frame
    try pod_protocol.writeFrame(&pod_conn, .input, data);
}
