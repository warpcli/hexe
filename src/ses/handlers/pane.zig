const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("../state.zig");
const ses = @import("../main.zig");

/// Handle get_pane_cwd request - queries /proc/<pid>/cwd for a pane
pub fn handleGetPaneCwd(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    const pane = ses_state.getPane(uuid) orelse {
        var response_buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_cwd\",\"uuid\":\"{s}\",\"cwd\":null}}\n", .{uuid});
        try conn.send(response);
        return;
    };

    // Get CWD from /proc/<child_pid>/cwd
    const cwd = pane.getProcCwd();

    var response_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
    const response = if (cwd) |c|
        try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_cwd\",\"uuid\":\"{s}\",\"cwd\":\"{s}\"}}\n", .{ uuid, c })
    else
        try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_cwd\",\"uuid\":\"{s}\",\"cwd\":null}}\n", .{uuid});

    try conn.send(response);
}

/// Handle create_pane request
pub fn handleCreatePane(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    _: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    // Get shell (default to $SHELL or /bin/sh)
    const shell = if (root.get("shell")) |s| s.string else (std.posix.getenv("SHELL") orelse "/bin/sh");

    // Get working directory
    const cwd: ?[]const u8 = if (root.get("cwd")) |c| c.string else null;

    // Get sticky options
    const sticky_pwd: ?[]const u8 = if (root.get("sticky_pwd")) |p| p.string else null;
    const sticky_key: ?u8 = if (root.get("sticky_key")) |k|
        if (k.string.len > 0) k.string[0] else null
    else
        null;

    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(ses_state.allocator);
    var extra_env_list: std.ArrayList([]const u8) = .empty;
    defer extra_env_list.deinit(ses_state.allocator);

    if (root.get("env")) |env_val| {
        if (env_val == .array) {
            for (env_val.array.items) |entry| {
                if (entry == .string and entry.string.len > 0) {
                    try env_list.append(ses_state.allocator, entry.string);
                }
            }
        }
    }

    if (root.get("extra_env")) |extra_val| {
        if (extra_val == .array) {
            for (extra_val.array.items) |entry| {
                if (entry == .string and entry.string.len > 0) {
                    try extra_env_list.append(ses_state.allocator, entry.string);
                }
            }
        }
    }

    const env_items: ?[]const []const u8 = if (env_list.items.len > 0) env_list.items else null;
    const extra_env_items: ?[]const []const u8 = if (extra_env_list.items.len > 0) extra_env_list.items else null;

    // Create pane
    const pane = try ses_state.createPane(client_id, shell, cwd, sticky_pwd, sticky_key, env_items, extra_env_items);
    ses_state.markDirty();
    ses.debugLog("pane created: {s} (pid={d})", .{ pane.uuid[0..8], pane.child_pid });

    // Send response with pod info (no PTY fd passing)
    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_created\",\"uuid\":\"{s}\",\"pid\":{d},\"socket\":\"{s}\"}}\n", .{
        pane.uuid,
        pane.child_pid,
        pane.pod_socket_path,
    });

    try conn.send(response);
}

/// Handle find_sticky request
pub fn handleFindSticky(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const pwd = (root.get("pwd") orelse return sendError(conn, "missing_pwd")).string;
    const key_str = (root.get("key") orelse return sendError(conn, "missing_key")).string;
    if (key_str.len == 0) return sendError(conn, "empty_key");
    const key = key_str[0];

    if (ses_state.findStickyPane(pwd, key)) |pane| {
        // Attach pane to this client
        _ = try ses_state.attachPane(pane.uuid, client_id);

        // Send response with pod info (no PTY fd passing)
        var response_buf: [512]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_found\",\"uuid\":\"{s}\",\"pid\":{d},\"socket\":\"{s}\"}}\n", .{
            pane.uuid,
            pane.child_pid,
            pane.pod_socket_path,
        });

        try conn.send(response);
    } else {
        try conn.sendLine("{\"type\":\"pane_not_found\"}");
    }
}

/// Handle reconnect request
pub fn handleReconnect(
    allocator: std.mem.Allocator,
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuids_val = root.get("pane_uuids") orelse return sendError(conn, "missing_pane_uuids");
    const uuids = uuids_val.array;

    const FoundPane = struct { uuid: [32]u8, pid: posix.pid_t, socket: []const u8 };
    var found_panes: std.ArrayList(FoundPane) = .empty;
    defer found_panes.deinit(allocator);

    for (uuids.items) |uuid_val| {
        const uuid_str = uuid_val.string;
        if (uuid_str.len != 32) continue;

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        if (ses_state.getPane(uuid)) |pane| {
            if (pane.state != .attached) {
                _ = ses_state.attachPane(uuid, client_id) catch continue;
            }
            try found_panes.append(allocator, .{
                .uuid = uuid,
                .pid = pane.child_pid,
                .socket = pane.pod_socket_path,
            });
        }
    }

    // Build response JSON
    var json_buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    var writer = stream.writer();

    try writer.writeAll("{\"type\":\"reconnected\",\"panes\":[");
    for (found_panes.items, 0..) |p, idx| {
        if (idx > 0) try writer.writeAll(",");
        try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d},\"socket\":\"{s}\"}}", .{ p.uuid, p.pid, p.socket });
    }
    try writer.writeAll("]}\n");

    try conn.send(stream.getWritten());
}

/// Handle orphan_pane request
pub fn handleOrphanPane(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    try ses_state.suspendPane(uuid);
    ses_state.markDirty();
    try conn.sendLine("{\"type\":\"ok\"}");
}

/// Handle list_orphaned request
pub fn handleListOrphaned(
    allocator: std.mem.Allocator,
    ses_state: *state.SesState,
    conn: *ipc.Connection,
) !void {
    const orphaned = try ses_state.getOrphanedPanes(allocator);
    defer allocator.free(orphaned);

    var json_buf: [8192]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    var writer = stream.writer();

    try writer.writeAll("{\"type\":\"orphaned_panes\",\"panes\":[");
    for (orphaned, 0..) |pane, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"uuid\":\"{s}\",\"pid\":{d}", .{ pane.uuid, pane.child_pid });
        if (pane.sticky_pwd) |pwd| {
            try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
        }
        if (pane.sticky_key) |key| {
            try writer.print(",\"sticky_key\":\"{c}\"", .{key});
        }
        const state_str = switch (pane.state) {
            .attached => "attached",
            .detached => "detached",
            .sticky => "sticky",
            .orphaned => "orphaned",
        };
        try writer.print(",\"state\":\"{s}\"}}", .{state_str});
    }
    try writer.writeAll("]}\n");

    try conn.send(stream.getWritten());
}

/// Handle adopt_pane request
pub fn handleAdoptPane(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    client_id: usize,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    const pane = try ses_state.attachPane(uuid, client_id);
    ses_state.markDirty();
    // Send response with pod info (no PTY fd passing)
    var response_buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buf, "{{\"type\":\"pane_found\",\"uuid\":\"{s}\",\"pid\":{d},\"socket\":\"{s}\"}}\n", .{
        pane.uuid,
        pane.child_pid,
        pane.pod_socket_path,
    });

    try conn.send(response);
}

/// Handle kill_pane request
pub fn handleKillPane(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    try ses_state.killPane(uuid);
    ses_state.markDirty();
    try conn.sendLine("{\"type\":\"ok\"}");
}

/// Handle set_sticky request - sets sticky_pwd and sticky_key on a pane
pub fn handleSetSticky(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    const pane = ses_state.panes.getPtr(uuid) orelse {
        ses.debugLog("set_sticky: pane not found {s}", .{uuid[0..8]});
        return sendError(conn, "pane_not_found");
    };

    // Set sticky_pwd if provided
    if (root.get("pwd")) |pwd_val| {
        const pwd = pwd_val.string;
        // Free old pwd if present
        if (pane.sticky_pwd) |old| {
            ses_state.allocator.free(old);
        }
        pane.sticky_pwd = ses_state.allocator.dupe(u8, pwd) catch null;
        ses_state.markDirty();
        ses.debugLog("set_sticky: {s} pwd={s}", .{ uuid[0..8], pwd });
    }

    // Set sticky_key if provided
    if (root.get("key")) |key_val| {
        const key_str = key_val.string;
        if (key_str.len > 0) {
            pane.sticky_key = key_str[0];
            ses_state.markDirty();
            ses.debugLog("set_sticky: {s} key={c}", .{ uuid[0..8], key_str[0] });
        }
    }

    try conn.sendLine("{\"type\":\"ok\"}");
}

/// Handle pane_info request
pub fn handlePaneInfo(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_str = (root.get("uuid") orelse return sendError(conn, "missing_uuid")).string;
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    const pane = ses_state.panes.get(uuid) orelse {
        return sendError(conn, "pane_not_found");
    };

    var json_buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    var writer = stream.writer();

    const state_str = switch (pane.state) {
        .attached => "attached",
        .detached => "detached",
        .sticky => "sticky",
        .orphaned => "orphaned",
    };

    try writer.print("{{\"type\":\"pane_info\",\"uuid\":\"{s}\",\"pid\":{d},\"state\":\"{s}\"", .{
        uuid,
        pane.child_pid,
        state_str,
    });

    // Include sticky info if present
    if (pane.sticky_pwd) |pwd| {
        try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
    }
    if (pane.sticky_key) |key| {
        try writer.print(",\"sticky_key\":\"{c}\"", .{key});
    }

    // Include attached_to client info
    if (pane.attached_to) |client_id| {
        try writer.print(",\"attached_to\":{d}", .{client_id});
        // Also include session info if available
        if (ses_state.getClient(client_id)) |client| {
            if (client.session_id) |sid| {
                const hex_id: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
                try writer.print(",\"session_id\":\"{s}\"", .{&hex_id});
            }
            if (client.session_name) |name| {
                try writer.print(",\"session_name\":\"{s}\"", .{name});
            }
        }
    }

    // Include session_id for detached panes
    if (pane.session_id) |sid| {
        const hex_id: [32]u8 = std.fmt.bytesToHex(&sid, .lower);
        try writer.print(",\"detached_session_id\":\"{s}\"", .{&hex_id});
    }

    try writer.print(",\"socket_path\":\"{s}\"", .{pane.pod_socket_path});

    // Timestamps
    try writer.print(",\"created_at\":{d}", .{pane.created_at});
    if (pane.orphaned_at) |orphaned| {
        try writer.print(",\"orphaned_at\":{d}", .{orphaned});
    }

    // Auxiliary info (synced from mux)
    try writer.print(",\"is_float\":{}", .{pane.is_float});
    try writer.print(",\"is_focused\":{}", .{pane.is_focused});
    const pane_type_str = switch (pane.pane_type) {
        .split => "split",
        .float => "float",
    };
    try writer.print(",\"pane_type\":\"{s}\"", .{pane_type_str});
    const creator_uuid = pane.created_from orelse uuid;
    try writer.print(",\"created_from\":\"{s}\"", .{creator_uuid});
    if (pane.focused_from) |focused_uuid| {
        try writer.print(",\"focused_from\":\"{s}\"", .{focused_uuid});
    }
    if (pane.layout_path) |path| {
        try writer.print(",\"layout_path\":\"{s}\"", .{path});
    }
    // Get CWD: prefer /proc/<pid>/cwd (authoritative), fall back to synced cwd
    const cwd = pane.getProcCwd() orelse pane.cwd;
    if (cwd) |c| {
        try writer.print(",\"cwd\":\"{s}\"", .{c});
    }
    if (pane.getProcForegroundProcess()) |fg| {
        try writer.print(",\"active_process\":\"{s}\"", .{fg.name});
        try writer.print(",\"active_pid\":{d}", .{fg.pid});
        try writer.print(",\"fg_process\":\"{s}\"", .{fg.name});
        try writer.print(",\"fg_pid\":{d}", .{fg.pid});
    } else if (pane.fg_process) |proc| {
        try writer.print(",\"fg_process\":\"{s}\"", .{proc});
    } else if (pane.getProcProcessName()) |proc| {
        try writer.print(",\"fg_process\":\"{s}\"", .{proc});
        if (pane.fg_pid == null) {
            try writer.print(",\"fg_pid\":{d}", .{pane.child_pid});
        }
    }
    if (pane.fg_pid) |pid| {
        try writer.print(",\"fg_pid\":{d}", .{pid});
    }
    if (pane.cols > 0 and pane.rows > 0) {
        try writer.print(",\"cols\":{d},\"rows\":{d}", .{ pane.cols, pane.rows });
    }
    if (pane.getProcTty()) |tty| {
        try writer.print(",\"tty\":\"{s}\"", .{tty});
    }
    if (pane.getProcProcessName()) |proc| {
        try writer.print(",\"base_process\":\"{s}\"", .{proc});
        try writer.print(",\"base_pid\":{d}", .{pane.child_pid});
    } else {
        try writer.print(",\"base_pid\":{d}", .{pane.child_pid});
    }
    try writer.print(",\"cursor_x\":{d},\"cursor_y\":{d}", .{ pane.cursor_x, pane.cursor_y });
    try writer.print(",\"cursor_style\":{d}", .{pane.cursor_style});
    try writer.print(",\"cursor_visible\":{}", .{pane.cursor_visible});
    try writer.print(",\"alt_screen\":{}", .{pane.alt_screen});

    try writer.writeAll("}\n");
    try conn.send(stream.getWritten());
}

/// Handle update_pane_aux request
pub fn handleUpdatePaneAux(
    ses_state: *state.SesState,
    conn: *ipc.Connection,
    root: std.json.ObjectMap,
    sendError: *const fn (*ipc.Connection, []const u8) anyerror!void,
) !void {
    const uuid_val = root.get("uuid") orelse return sendError(conn, "missing_uuid");
    const uuid_str = switch (uuid_val) {
        .string => |s| s,
        else => return sendError(conn, "invalid_uuid"),
    };
    if (uuid_str.len != 32) return sendError(conn, "invalid_uuid");

    var uuid: [32]u8 = undefined;
    @memcpy(&uuid, uuid_str[0..32]);

    const pane = ses_state.panes.getPtr(uuid) orelse {
        return sendError(conn, "pane_not_found");
    };

    // Update is_float
    if (root.get("is_float")) |v| {
        switch (v) {
            .bool => |b| pane.is_float = b,
            else => {},
        }
    }

    // Update is_focused
    if (root.get("is_focused")) |v| {
        switch (v) {
            .bool => |b| pane.is_focused = b,
            else => {},
        }
    }

    // Update pane_type
    if (root.get("pane_type")) |v| {
        switch (v) {
            .string => |s| {
                if (std.mem.eql(u8, s, "float")) {
                    pane.pane_type = .float;
                } else {
                    pane.pane_type = .split;
                }
            },
            else => {},
        }
    }

    // Update created_from (only if a string value is provided, null means "don't update")
    if (root.get("created_from")) |v| {
        switch (v) {
            .string => |s| {
                if (s.len == 32) {
                    var created_uuid: [32]u8 = undefined;
                    @memcpy(&created_uuid, s[0..32]);
                    pane.created_from = created_uuid;
                    ses.debugLogUuid(&uuid, "created_from <- {s}", .{created_uuid[0..8]});
                }
            },
            else => {},
        }
    }

    // Update focused_from (only if a string value is provided, null means "don't update")
    if (root.get("focused_from")) |v| {
        switch (v) {
            .string => |s| {
                if (s.len == 32) {
                    var focused_uuid: [32]u8 = undefined;
                    @memcpy(&focused_uuid, s[0..32]);
                    pane.focused_from = focused_uuid;
                    ses.debugLogUuid(&uuid, "focused_from <- {s}", .{focused_uuid[0..8]});
                }
            },
            else => {},
        }
    }

    // Update cursor position
    if (root.get("cursor_x")) |v| {
        switch (v) {
            .integer => |i| pane.cursor_x = @intCast(@max(0, i)),
            else => {},
        }
    }
    if (root.get("cursor_y")) |v| {
        switch (v) {
            .integer => |i| pane.cursor_y = @intCast(@max(0, i)),
            else => {},
        }
    }

    if (root.get("cursor_style")) |v| {
        switch (v) {
            .integer => |i| pane.cursor_style = @intCast(@max(0, i)),
            else => {},
        }
    }
    if (root.get("cursor_visible")) |v| {
        switch (v) {
            .bool => |b| pane.cursor_visible = b,
            else => {},
        }
    }
    if (root.get("alt_screen")) |v| {
        switch (v) {
            .bool => |b| pane.alt_screen = b,
            else => {},
        }
    }

    if (root.get("cols")) |v| {
        switch (v) {
            .integer => |i| pane.cols = @intCast(@max(0, i)),
            else => {},
        }
    }
    if (root.get("rows")) |v| {
        switch (v) {
            .integer => |i| pane.rows = @intCast(@max(0, i)),
            else => {},
        }
    }

    // Update CWD (owned string)
    if (root.get("cwd")) |v| {
        switch (v) {
            .string => |s| {
                if (pane.cwd) |old| {
                    ses_state.allocator.free(old);
                }
                pane.cwd = ses_state.allocator.dupe(u8, s) catch null;
            },
            else => {},
        }
    }

    // Update foreground process name (owned string)
    if (root.get("fg_process")) |v| {
        switch (v) {
            .string => |s| {
                if (pane.fg_process) |old| {
                    ses_state.allocator.free(old);
                }
                pane.fg_process = ses_state.allocator.dupe(u8, s) catch null;
            },
            else => {},
        }
    }

    // Update foreground process PID
    if (root.get("fg_pid")) |v| {
        switch (v) {
            .integer => |i| pane.fg_pid = @intCast(i),
            else => {},
        }
    }

    if (root.get("layout_path")) |v| {
        switch (v) {
            .string => |s| {
                if (pane.layout_path) |old| {
                    ses_state.allocator.free(old);
                }
                pane.layout_path = ses_state.allocator.dupe(u8, s) catch null;
            },
            else => {},
        }
    }

    try conn.sendLine("{\"type\":\"ok\"}");
}
