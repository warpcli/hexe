const std = @import("std");
const core = @import("core");
const wire = core.wire;
const posix = std.posix;

const print = std.debug.print;

/// Show SES daemon resource statistics
pub fn run(allocator: std.mem.Allocator) !void {
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

    // Request status
    try wire.writeControl(fd, .status, &.{});

    // Read response
    const hdr = try wire.readControlHeader(fd);
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .ok) {
        print("Error: Failed to retrieve status\n", .{});
        return error.StatusFailed;
    }

    // For now, show basic info from list operations
    // Request sessions list to count
    try wire.writeControl(fd, .list_sessions, &.{});
    const sessions_hdr = try wire.readControlHeader(fd);
    const sessions_msg_type: wire.MsgType = @enumFromInt(sessions_hdr.msg_type);

    if (sessions_msg_type != .sessions_list) {
        print("Error: Unexpected response\n", .{});
        return error.UnexpectedResponse;
    }

    const payload = try allocator.alloc(u8, sessions_hdr.payload_len);
    defer allocator.free(payload);
    try wire.readExact(fd, payload);

    // Count sessions
    var session_count: usize = 0;
    var total_panes: usize = 0;
    var off: usize = 0;

    while (off + @sizeOf(wire.DetachedSessionEntry) <= payload.len) {
        const entry_bytes = payload[off..][0..@sizeOf(wire.DetachedSessionEntry)];
        const entry = std.mem.bytesToValue(wire.DetachedSessionEntry, entry_bytes);
        off += @sizeOf(wire.DetachedSessionEntry);

        const name_end = off + entry.name_len;
        if (name_end > payload.len) break;
        off = name_end;

        session_count += 1;
        total_panes += entry.pane_count;
    }

    // Display resource statistics
    print("\n━━━ SES Daemon Resource Statistics ━━━\n\n", .{});

    print("📊 Sessions\n", .{});
    print("  Detached sessions:  {d}\n", .{session_count});
    print("  Total panes:        {d}\n\n", .{total_panes});

    // Load resource limits from env
    const limits = core.resource_limits.ResourceLimits.fromEnv();

    print("⚙️  Resource Limits\n", .{});
    print("  Max connections:    {d}\n", .{limits.max_connections});
    print("  Max sessions:       {d}\n", .{limits.max_sessions});
    print("  Max panes/session:  {d}\n", .{limits.max_panes_per_session});
    print("  Max memory/session: {d} MB\n", .{limits.max_memory_per_session_mb});
    print("  Max conn/minute:    {d}\n\n", .{limits.max_connections_per_minute});

    print("💡 Configuration\n", .{});
    print("  Set limits via environment variables:\n", .{});
    print("    HEXE_MAX_CONNECTIONS\n", .{});
    print("    HEXE_MAX_SESSIONS\n", .{});
    print("    HEXE_MAX_PANES_PER_SESSION\n", .{});
    print("    HEXE_MAX_MEMORY_PER_SESSION_MB\n", .{});
    print("    HEXE_MAX_CONNECTIONS_PER_MINUTE\n\n", .{});
}
