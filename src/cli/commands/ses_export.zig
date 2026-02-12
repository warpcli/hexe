const std = @import("std");
const core = @import("core");
const wire = core.wire;
const posix = std.posix;
const shared = @import("shared.zig");

const print = std.debug.print;

/// Export a detached session to JSON
pub fn run(allocator: std.mem.Allocator, session_id: []const u8, output_path: []const u8) !void {

    // Connect to SES
    const ses_path = try core.ipc.getSesSocketPath(allocator);
    defer allocator.free(ses_path);

    var client = core.ipc.Client.connect(ses_path) catch {
        print("Error: Could not connect to ses daemon\n", .{});
        print("Make sure the daemon is running with: hexe ses daemon\n", .{});
        return error.SesNotRunning;
    };
    defer client.close();

    const fd = client.fd;

    // Send handshake
    _ = try posix.write(fd, &.{wire.SES_HANDSHAKE_CLI});

    // Request list of detached sessions
    try wire.writeControl(fd, .list_sessions, &.{});

    // Read response
    const hdr = try wire.readControlHeader(fd);
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .sessions_list) {
        print("Error: Unexpected response from ses daemon\n", .{});
        return error.UnexpectedResponse;
    }

    const payload = try allocator.alloc(u8, hdr.payload_len);
    defer allocator.free(payload);
    try wire.readExact(fd, payload);

    // Parse detached sessions list
    var off: usize = 0;
    var found = false;
    var target_session_id: [32]u8 = undefined;

    while (off + @sizeOf(wire.DetachedSessionEntry) <= payload.len) {
        const entry_bytes = payload[off..][0..@sizeOf(wire.DetachedSessionEntry)];
        const entry = std.mem.bytesToValue(wire.DetachedSessionEntry, entry_bytes);
        off += @sizeOf(wire.DetachedSessionEntry);

        const name_end = off + entry.name_len;
        if (name_end > payload.len) break;
        const name = payload[off..name_end];
        off = name_end;

        // Check if this matches the requested session (by name or ID prefix)
        if (std.mem.eql(u8, name, session_id) or
            std.mem.startsWith(u8, &entry.session_id, session_id) or
            std.ascii.eqlIgnoreCase(name, session_id))
        {
            target_session_id = entry.session_id;
            found = true;
            break;
        }
    }

    if (!found) {
        print("Error: Session '{s}' not found\n", .{session_id});
        print("Use 'hexe ses list' to see available detached sessions\n", .{});
        return error.SessionNotFound;
    }

    // Request full session state
    try wire.writeControl(fd, .get_session_state, std.mem.asBytes(&target_session_id));

    // Read session state response
    const state_hdr = try wire.readControlHeader(fd);
    const state_msg_type: wire.MsgType = @enumFromInt(state_hdr.msg_type);
    if (state_msg_type != .session_state) {
        print("Error: Failed to retrieve session state\n", .{});
        return error.StateRetrievalFailed;
    }

    const state_payload = try allocator.alloc(u8, state_hdr.payload_len);
    defer allocator.free(state_payload);
    try wire.readExact(fd, state_payload);

    // Write to file or stdout
    if (output_path.len > 0) {
        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();
        try file.writeAll(state_payload);
        print("✓ Session exported to: {s}\n", .{output_path});
    } else {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(state_payload);
    }
}
