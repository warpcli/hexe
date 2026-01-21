const std = @import("std");
const posix = std.posix;
const core = @import("core");

/// Client for communicating with the ses daemon
pub const SesClient = struct {
    allocator: std.mem.Allocator,
    conn: ?core.ipc.Connection,
    just_started_daemon: bool,
    debug: bool,
    log_file: ?[]const u8,

    // Registration info
    session_id: [32]u8, // mux UUID as hex string
    session_name: []const u8, // Pokemon name
    keepalive: bool,

    pub fn init(allocator: std.mem.Allocator, session_id: [32]u8, session_name: []const u8, keepalive: bool, debug: bool, log_file: ?[]const u8) SesClient {
        return .{
            .allocator = allocator,
            .conn = null,
            .just_started_daemon = false,
            .debug = debug,
            .log_file = log_file,
            .session_id = session_id,
            .session_name = session_name,
            .keepalive = keepalive,
        };
    }

    pub fn deinit(self: *SesClient) void {
        if (self.conn) |*c| {
            c.close();
        }
    }

    /// Connect to the ses daemon, starting it if necessary
    pub fn connect(self: *SesClient) !void {
        const socket_path = try core.ipc.getSesSocketPath(self.allocator);
        defer self.allocator.free(socket_path);

        // Try to connect to existing daemon first
        if (core.ipc.Client.connect(socket_path)) |client| {
            self.conn = client.toConnection();
            self.just_started_daemon = false;
            try self.register();
            return;
        } else |err| {
            if (err != error.ConnectionRefused and err != error.FileNotFound) {
                return err;
            }
        }

        // Daemon not running, start it
        try self.startSes();
        self.just_started_daemon = true;

        // Wait for daemon to be ready
        std.Thread.sleep(200 * std.time.ns_per_ms);

        // Retry connection
        const client = try core.ipc.Client.connect(socket_path);
        self.conn = client.toConnection();
        try self.register();
    }

    /// Register with ses - send session_id, session_name, and keepalive preference
    fn register(self: *SesClient) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"register\",\"session_id\":\"{s}\",\"session_name\":\"{s}\",\"keepalive\":{}}}", .{
            self.session_id,
            self.session_name,
            self.keepalive,
        });
        try conn.sendLine(msg);

        // Wait for response
        var resp_buf: [128]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Verify it's a successful registration
        if (std.mem.indexOf(u8, line.?, "registered") == null) {
            return error.RegistrationFailed;
        }
    }

    /// Update session info and re-register with ses (used after reattach)
    pub fn updateSession(self: *SesClient, session_id: [32]u8, session_name: []const u8) !void {
        self.session_id = session_id;
        self.session_name = session_name;
        try self.register();
    }

    /// Sync current mux state to ses (for crash recovery)
    /// Tell ses this mux is exiting normally.
    ///
    /// This avoids ses treating the disconnect as a crash (keepalive auto-detach).
    pub fn shutdown(self: *SesClient, preserve_sticky: bool) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"disconnect\",\"mode\":\"shutdown\",\"preserve_sticky\":{}}}", .{preserve_sticky});
        // Best-effort: don't block on a reply (mux is exiting).
        conn.sendLine(msg) catch {};
    }

    pub fn syncState(self: *SesClient, mux_state_json: []const u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build message with mux state as escaped JSON string
        const msg_size = 64 + mux_state_json.len * 2;
        const msg_buf = self.allocator.alloc(u8, msg_size) catch return error.OutOfMemory;
        defer self.allocator.free(msg_buf);

        var stream = std.io.fixedBufferStream(msg_buf);
        var writer = stream.writer();
        writer.writeAll("{\"type\":\"sync_state\",\"mux_state\":\"") catch return error.WriteError;

        // Escape the JSON string
        for (mux_state_json) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch return error.WriteError,
                '\\' => writer.writeAll("\\\\") catch return error.WriteError,
                '\n' => writer.writeAll("\\n") catch return error.WriteError,
                '\r' => writer.writeAll("\\r") catch return error.WriteError,
                '\t' => writer.writeAll("\\t") catch return error.WriteError,
                else => writer.writeByte(c) catch return error.WriteError,
            }
        }
        writer.writeAll("\"}") catch return error.WriteError;

        try conn.sendLine(stream.getWritten());

        // Wait for response
        var resp_buf: [128]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Start the ses daemon
    fn startSes(self: *SesClient) !void {
        // Fork and exec hexe ses daemon
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);

        try args_list.append(self.allocator, "hexe");
        try args_list.append(self.allocator, "ses");
        try args_list.append(self.allocator, "daemon");
        if (self.debug) {
            try args_list.append(self.allocator, "--debug");
        }
        if (self.log_file) |path| {
            if (path.len > 0) {
                try args_list.append(self.allocator, "--logfile");
                try args_list.append(self.allocator, path);
            }
        }

        var child = std.process.Child.init(args_list.items, std.heap.page_allocator);
        child.spawn() catch |err| {
            std.debug.print("Failed to start ses daemon: {}\n", .{err});
            return err;
        };
        // Don't wait - it daemonizes itself
        _ = child.wait() catch {};
    }

    /// Check if connected to ses
    pub fn isConnected(self: *SesClient) bool {
        return self.conn != null;
    }

    /// Create a new pane via ses.
    /// Returns the pane UUID and the pod socket path (owned; caller frees).
    pub fn createPane(
        self: *SesClient,
        shell: ?[]const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
        env: ?[]const []const u8,
        extra_env: ?[]const []const u8,
    ) !struct { uuid: [32]u8, socket_path: []u8, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build request JSON
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var writer = buf.writer(self.allocator);

        try writer.writeAll("{\"type\":\"create_pane\"");
        if (shell) |s| {
            try writer.print(",\"shell\":\"{s}\"", .{s});
        }
        if (cwd) |dir| {
            try writer.print(",\"cwd\":\"{s}\"", .{dir});
        }
        if (sticky_pwd) |pwd| {
            try writer.print(",\"sticky_pwd\":\"{s}\"", .{pwd});
        }
        if (sticky_key) |key| {
            try writer.print(",\"sticky_key\":\"{c}\"", .{key});
        }
        if (env) |vars| {
            try writer.writeAll(",\"env\":[");
            for (vars, 0..) |entry, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{entry});
            }
            try writer.writeAll("]");
        }
        if (extra_env) |vars| {
            try writer.writeAll(",\"extra_env\":[");
            for (vars, 0..) |entry, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{entry});
            }
            try writer.writeAll("]");
        }
        try writer.writeAll("}");

        try conn.sendLine(buf.items);

        // Receive response
        var resp_buf: [1024]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) return error.SesError;
        if (!std.mem.eql(u8, msg_type, "pane_created")) return error.UnexpectedResponse;

        const uuid_str = (root.get("uuid") orelse return error.InvalidResponse).string;
        const pid = (root.get("pid") orelse return error.InvalidResponse).integer;
        const socket_str = (root.get("socket") orelse return error.InvalidResponse).string;

        var uuid: [32]u8 = undefined;
        if (uuid_str.len != 32) return error.InvalidUuid;
        @memcpy(&uuid, uuid_str[0..32]);

        const socket_owned = try self.allocator.dupe(u8, socket_str);

        return .{
            .uuid = uuid,
            .socket_path = socket_owned,
            .pid = @intCast(pid),
        };
    }

    /// Find a sticky pane (for pwd floats).
    /// Returns pod socket path (owned; caller frees).
    pub fn findStickyPane(self: *SesClient, pwd: []const u8, key: u8) !?struct { uuid: [32]u8, socket_path: []u8, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"find_sticky\",\"pwd\":\"{s}\",\"key\":\"{c}\"}}", .{ pwd, key });
        try conn.sendLine(msg);

        var resp_buf: [1024]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "pane_not_found")) return null;
        if (!std.mem.eql(u8, msg_type, "pane_found")) return error.UnexpectedResponse;

        const uuid_str = (root.get("uuid") orelse return error.InvalidResponse).string;
        const pid = (root.get("pid") orelse return error.InvalidResponse).integer;
        const socket_str = (root.get("socket") orelse return error.InvalidResponse).string;

        if (uuid_str.len != 32) return error.InvalidUuid;
        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const socket_owned = try self.allocator.dupe(u8, socket_str);

        return .{ .uuid = uuid, .socket_path = socket_owned, .pid = @intCast(pid) };
    }

    /// Orphan a pane (manual suspend)
    pub fn orphanPane(self: *SesClient, uuid: [32]u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"orphan_pane\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        // Wait for OK response
        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Set sticky info on a pane (for sticky floats before orphaning)
    pub fn setSticky(self: *SesClient, uuid: [32]u8, pwd: []const u8, key: u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"set_sticky\",\"uuid\":\"{s}\",\"pwd\":\"{s}\",\"key\":\"{c}\"}}", .{ uuid, pwd, key });
        try conn.sendLine(msg);

        // Wait for OK response
        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Kill a pane
    pub fn killPane(self: *SesClient, uuid: [32]u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"kill_pane\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        // Wait for OK response
        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Pane auxiliary info returned from getPaneAux
    pub const PaneAuxInfo = struct {
        created_from: ?[32]u8,
        focused_from: ?[32]u8,
    };

    /// Get auxiliary pane info (created_from, focused_from) from ses
    pub fn getPaneAux(self: *SesClient, uuid: [32]u8) !PaneAuxInfo {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        // Wait for response
        var resp_buf: [2048]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse JSON response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "error")) {
                return error.PaneNotFound;
            }
        }

        var info: PaneAuxInfo = .{
            .created_from = null,
            .focused_from = null,
        };

        if (root.get("created_from")) |cf| {
            if (cf == .string and cf.string.len == 32) {
                var created: [32]u8 = undefined;
                @memcpy(&created, cf.string[0..32]);
                info.created_from = created;
            }
        }

        if (root.get("focused_from")) |ff| {
            if (ff == .string and ff.string.len == 32) {
                var focused: [32]u8 = undefined;
                @memcpy(&focused, ff.string[0..32]);
                info.focused_from = focused;
            }
        }

        return info;
    }

    /// Get current working directory from /proc/<pid>/cwd via ses
    /// Returns an owned slice that the caller must free with the allocator.
    pub fn getPaneCwd(self: *SesClient, uuid: [32]u8) ?[]u8 {
        const conn = &(self.conn orelse return null);

        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"get_pane_cwd\",\"uuid\":\"{s}\"}}", .{uuid}) catch return null;
        conn.sendLine(msg) catch return null;

        // Wait for response
        var resp_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        const line = conn.recvLine(&resp_buf) catch return null;
        if (line == null) return null;

        // Parse JSON response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch return null;
        defer parsed.deinit();

        const root = parsed.value.object;
        if (root.get("cwd")) |cwd| {
            if (cwd == .string) {
                // Duplicate the string since parsed will be freed
                return self.allocator.dupe(u8, cwd.string) catch return null;
            }
        }
        return null;
    }

    /// Ping ses to check if it's alive
    pub fn ping(self: *SesClient) !bool {
        const conn = &(self.conn orelse return false);

        try conn.sendLine("{\"type\":\"ping\"}");

        var resp_buf: [64]u8 = undefined;
        const line = conn.recvLine(&resp_buf) catch return false;
        if (line == null) return false;

        return std.mem.indexOf(u8, line.?, "pong") != null;
    }

    /// Pane type enum for auxiliary info
    pub const PaneType = enum {
        split,
        float,
    };

    /// Update auxiliary pane info (synced from mux to ses)
    pub fn updatePaneAux(
        self: *SesClient,
        uuid: [32]u8,
        is_float: bool,
        is_focused: bool,
        pane_type: PaneType,
        created_from: ?[32]u8,
        focused_from: ?[32]u8,
        cursor_pos: ?struct { x: u16, y: u16 },
        cursor_style: ?u8,
        cursor_visible: ?bool,
        in_alt_screen: ?bool,
        size: ?struct { cols: u16, rows: u16 },
        cwd: ?[]const u8,
        fg_process: ?[]const u8,
        fg_pid: ?posix.pid_t,
        layout_path: ?[]const u8,
    ) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        var writer = stream.writer();

        const pane_type_str = switch (pane_type) {
            .split => "split",
            .float => "float",
        };

        try writer.print("{{\"type\":\"update_pane_aux\",\"uuid\":\"{s}\",\"is_float\":{},\"is_focused\":{},\"pane_type\":\"{s}\"", .{
            uuid,
            is_float,
            is_focused,
            pane_type_str,
        });

        if (created_from) |cf| {
            try writer.print(",\"created_from\":\"{s}\"", .{cf});
        } else {
            try writer.writeAll(",\"created_from\":null");
        }

        if (focused_from) |ff| {
            try writer.print(",\"focused_from\":\"{s}\"", .{ff});
        } else {
            try writer.writeAll(",\"focused_from\":null");
        }

        if (cursor_pos) |pos| {
            try writer.print(",\"cursor_x\":{d},\"cursor_y\":{d}", .{ pos.x, pos.y });
        }

        if (cursor_style) |style| {
            try writer.print(",\"cursor_style\":{d}", .{style});
        }
        if (cursor_visible) |visible| {
            try writer.print(",\"cursor_visible\":{}", .{visible});
        }
        if (in_alt_screen) |alt| {
            try writer.print(",\"alt_screen\":{}", .{alt});
        }

        if (size) |s| {
            try writer.print(",\"cols\":{d},\"rows\":{d}", .{ s.cols, s.rows });
        }

        if (cwd) |c| {
            try writer.print(",\"cwd\":\"{s}\"", .{c});
        }

        if (fg_process) |p| {
            try writer.print(",\"fg_process\":\"{s}\"", .{p});
        }

        if (fg_pid) |pid| {
            try writer.print(",\"fg_pid\":{d}", .{pid});
        }

        if (layout_path) |path| {
            try writer.print(",\"layout_path\":\"{s}\"", .{path});
        }

        try writer.writeAll("}");

        try conn.sendLine(stream.getWritten());

        // Wait for OK response
        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;
    }

    /// Adopt an orphaned pane
    pub fn adoptPane(self: *SesClient, uuid: [32]u8) !struct { uuid: [32]u8, socket_path: []u8, pid: posix.pid_t } {
        const conn = &(self.conn orelse return error.NotConnected);

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"adopt_pane\",\"uuid\":\"{s}\"}}", .{uuid});
        try conn.sendLine(msg);

        var resp_buf: [1024]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch return error.InvalidResponse;
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;
        if (std.mem.eql(u8, msg_type, "error")) return error.SesError;
        if (!std.mem.eql(u8, msg_type, "pane_found")) return error.UnexpectedResponse;

        const pid = (root.get("pid") orelse return error.InvalidResponse).integer;
        const socket_str = (root.get("socket") orelse return error.InvalidResponse).string;
        const socket_owned = try self.allocator.dupe(u8, socket_str);

        return .{ .uuid = uuid, .socket_path = socket_owned, .pid = @intCast(pid) };
    }

    /// List orphaned panes
    pub fn listOrphanedPanes(self: *SesClient, out_buf: []OrphanedPaneInfo) !usize {
        const conn = &(self.conn orelse return error.NotConnected);

        try conn.sendLine("{\"type\":\"list_orphaned\"}");

        var resp_buf: [4096]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (!std.mem.eql(u8, msg_type, "orphaned_panes")) {
            return error.UnexpectedResponse;
        }

        const panes = (root.get("panes") orelse return error.InvalidResponse).array;
        var count: usize = 0;

        for (panes.items) |pane_val| {
            if (count >= out_buf.len) break;
            const pane = pane_val.object;

            const uuid_str = (pane.get("uuid") orelse continue).string;
            if (uuid_str.len != 32) continue;

            var info: OrphanedPaneInfo = undefined;
            @memcpy(&info.uuid, uuid_str[0..32]);
            info.pid = @intCast((pane.get("pid") orelse continue).integer);

            out_buf[count] = info;
            count += 1;
        }

        return count;
    }

    /// Detach session - keeps panes grouped for later reattach
    /// Sends full mux state JSON for storage
    /// Returns session_id (hex string)
    /// Detach session with a specific session ID (mux UUID)
    /// The session_id should be a 32-char hex string (the mux's UUID)
    pub fn detachSession(self: *SesClient, session_id: [32]u8, mux_state_json: []const u8) !void {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build message with session_id and mux state as escaped JSON string
        // {"type":"detach_session","session_id":"<uuid>","mux_state":"<escaped_json>"}
        // Allocate buffer for the full message (doubled for escaping)
        const msg_size = 128 + mux_state_json.len * 2;
        const msg_buf = self.allocator.alloc(u8, msg_size) catch return error.OutOfMemory;
        defer self.allocator.free(msg_buf);

        var stream = std.io.fixedBufferStream(msg_buf);
        var writer = stream.writer();
        writer.print("{{\"type\":\"detach_session\",\"session_id\":\"{s}\",\"mux_state\":\"", .{session_id}) catch return error.WriteError;
        // Escape the JSON string
        for (mux_state_json) |c| {
            switch (c) {
                '"' => writer.writeAll("\\\"") catch return error.WriteError,
                '\\' => writer.writeAll("\\\\") catch return error.WriteError,
                '\n' => writer.writeAll("\\n") catch return error.WriteError,
                '\r' => writer.writeAll("\\r") catch return error.WriteError,
                '\t' => writer.writeAll("\\t") catch return error.WriteError,
                else => writer.writeByte(c) catch return error.WriteError,
            }
        }
        writer.writeAll("\"}") catch return error.WriteError;

        try conn.sendLine(stream.getWritten());

        var resp_buf: [256]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) {
            return error.DetachFailed;
        }

        if (!std.mem.eql(u8, msg_type, "session_detached")) {
            return error.UnexpectedResponse;
        }
    }

    /// Result of reattaching a session
    pub const ReattachResult = struct {
        mux_state_json: []const u8, // Owned - caller must free with allocator
        pane_uuids: [][32]u8, // Owned - caller must free
    };

    /// Reattach to a detached session
    /// Returns the full mux state and list of pane UUIDs to adopt
    pub fn reattachSession(self: *SesClient, session_id: []const u8) !?ReattachResult {
        const conn = &(self.conn orelse return error.NotConnected);

        // Build request
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"reattach\",\"session_id\":\"{s}\"}}", .{session_id});
        try conn.sendLine(msg);

        // Response can be large, allocate dynamically
        var resp_buf: [65536]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (std.mem.eql(u8, msg_type, "error")) {
            return null;
        }

        if (!std.mem.eql(u8, msg_type, "session_reattached")) {
            return error.UnexpectedResponse;
        }

        // Get mux state (it's a JSON string that was escaped in the response)
        const mux_state_str = (root.get("mux_state") orelse return error.InvalidResponse).string;
        // Copy to owned memory
        const mux_state_json = self.allocator.dupe(u8, mux_state_str) catch return error.OutOfMemory;
        errdefer self.allocator.free(mux_state_json);

        // Get pane UUIDs
        const panes_array = (root.get("panes") orelse return error.InvalidResponse).array;
        var pane_uuids = self.allocator.alloc([32]u8, panes_array.items.len) catch return error.OutOfMemory;
        errdefer self.allocator.free(pane_uuids);

        for (panes_array.items, 0..) |pane_val, i| {
            const uuid_str = pane_val.string;
            if (uuid_str.len == 32) {
                @memcpy(&pane_uuids[i], uuid_str[0..32]);
            }
        }

        return .{
            .mux_state_json = mux_state_json,
            .pane_uuids = pane_uuids,
        };
    }

    /// List detached sessions
    pub fn listSessions(self: *SesClient, out_buf: []DetachedSessionInfo) !usize {
        const conn = &(self.conn orelse return error.NotConnected);

        try conn.sendLine("{\"type\":\"list_sessions\"}");

        var resp_buf: [4096]u8 = undefined;
        const line = try conn.recvLine(&resp_buf);
        if (line == null) return error.ConnectionClosed;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line.?, .{}) catch {
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = (root.get("type") orelse return error.InvalidResponse).string;

        if (!std.mem.eql(u8, msg_type, "sessions")) {
            return error.UnexpectedResponse;
        }

        const sessions = (root.get("sessions") orelse return error.InvalidResponse).array;
        var count: usize = 0;

        for (sessions.items) |sess_val| {
            if (count >= out_buf.len) break;
            const sess = sess_val.object;

            const sid_str = (sess.get("session_id") orelse continue).string;
            if (sid_str.len != 32) continue;

            var info: DetachedSessionInfo = undefined;
            @memcpy(&info.session_id, sid_str[0..32]);
            info.pane_count = @intCast((sess.get("pane_count") orelse continue).integer);

            // Get session name
            if (sess.get("session_name")) |name_val| {
                const name = name_val.string;
                const name_len = @min(name.len, 32);
                @memcpy(info.session_name[0..name_len], name[0..name_len]);
                info.session_name_len = name_len;
            } else {
                info.session_name_len = 0;
            }

            out_buf[count] = info;
            count += 1;
        }

        return count;
    }
};

pub const OrphanedPaneInfo = struct {
    uuid: [32]u8,
    pid: posix.pid_t,
};

pub const DetachedSessionInfo = struct {
    session_id: [32]u8,
    session_name: [32]u8,
    session_name_len: usize,
    pane_count: usize,
};
