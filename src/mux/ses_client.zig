const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const mux = @import("main.zig");

/// Client for communicating with the ses daemon using binary protocol.
/// Opens two channels:
///   - ctl_fd (handshake 0x01): binary control messages
///   - vt_fd (handshake 0x02): multiplexed VT data (MuxVtHeader frames)
pub const SesClient = struct {
    allocator: std.mem.Allocator,
    ctl_fd: ?posix.fd_t,
    vt_fd: ?posix.fd_t,
    just_started_daemon: bool,
    debug: bool,
    log_file: ?[]const u8,

    // Registration info
    session_id: [32]u8, // mux UUID as hex string
    session_name: []const u8, // Pokemon name
    keepalive: bool,

    // Pending async request tracking
    pending_cwd_uuid: ?[32]u8 = null,

    pub fn init(allocator: std.mem.Allocator, session_id: [32]u8, session_name: []const u8, keepalive: bool, debug: bool, log_file: ?[]const u8) SesClient {
        return .{
            .allocator = allocator,
            .ctl_fd = null,
            .vt_fd = null,
            .just_started_daemon = false,
            .debug = debug,
            .log_file = log_file,
            .session_id = session_id,
            .session_name = session_name,
            .keepalive = keepalive,
        };
    }

    pub fn deinit(self: *SesClient) void {
        if (self.ctl_fd) |fd| posix.close(fd);
        if (self.vt_fd) |fd| posix.close(fd);
        self.ctl_fd = null;
        self.vt_fd = null;
    }

    /// Connect to the ses daemon, starting it if necessary.
    /// Opens CTL channel, registers, then opens VT channel.
    pub fn connect(self: *SesClient) !void {
        const socket_path = try core.ipc.getSesSocketPath(self.allocator);
        defer self.allocator.free(socket_path);

        // Try to connect to existing daemon first
        if (self.connectCtl(socket_path)) {
            self.just_started_daemon = false;
        } else {
            // Daemon not running, start it
            try self.startSes();
            self.just_started_daemon = true;

            // Wait for daemon to be ready
            std.Thread.sleep(200 * std.time.ns_per_ms);

            // Retry connection
            if (!self.connectCtl(socket_path)) {
                return error.ConnectionRefused;
            }
        }

        // Register on CTL channel first, so SES knows our session_id.
        try self.register();

        // Now open VT channel — SES can match our session_id.
        if (!self.connectVt(socket_path)) {
            return error.ConnectionRefused;
        }
    }

    /// Open the control channel to SES.
    fn connectCtl(self: *SesClient, socket_path: []const u8) bool {
        const ctl_client = core.ipc.Client.connect(socket_path) catch return false;
        const ctl_fd = ctl_client.fd;

        // Set non-blocking — periodic sync calls must not block the main loop.
        const O_NONBLOCK: usize = 0o4000;
        const flags = posix.fcntl(ctl_fd, posix.F.GETFL, 0) catch {
            posix.close(ctl_fd);
            return false;
        };
        _ = posix.fcntl(ctl_fd, posix.F.SETFL, flags | O_NONBLOCK) catch {
            posix.close(ctl_fd);
            return false;
        };

        const ctl_handshake = [_]u8{wire.SES_HANDSHAKE_MUX_CTL};
        wire.writeAll(ctl_fd, &ctl_handshake) catch {
            posix.close(ctl_fd);
            return false;
        };
        self.ctl_fd = ctl_fd;
        mux.debugLog("ses ctl connected: fd={d}", .{ctl_fd});
        return true;
    }

    /// Open the VT data channel to SES.
    fn connectVt(self: *SesClient, socket_path: []const u8) bool {
        const vt_client = core.ipc.Client.connect(socket_path) catch return false;
        const vt_fd = vt_client.fd;

        // Set non-blocking — the VT fd is polled in the event loop, must not block.
        const O_NONBLOCK: usize = 0o4000;
        const flags = posix.fcntl(vt_fd, posix.F.GETFL, 0) catch {
            posix.close(vt_fd);
            return false;
        };
        _ = posix.fcntl(vt_fd, posix.F.SETFL, flags | O_NONBLOCK) catch {
            posix.close(vt_fd);
            return false;
        };

        const vt_handshake = [_]u8{wire.SES_HANDSHAKE_MUX_VT};
        wire.writeAll(vt_fd, &vt_handshake) catch {
            posix.close(vt_fd);
            return false;
        };
        // Send 32-byte hex session_id so SES can match us to the registered client.
        wire.writeAll(vt_fd, &self.session_id) catch {
            posix.close(vt_fd);
            return false;
        };
        self.vt_fd = vt_fd;
        mux.debugLog("ses vt connected: fd={d}", .{vt_fd});
        return true;
    }

    /// Register with ses — send session_id, session_name, and keepalive preference.
    fn register(self: *SesClient) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        mux.debugLog("registering session={s} name={s}", .{ self.session_id[0..8], self.session_name });

        var reg: wire.Register = .{
            .session_id = self.session_id,
            .keepalive = if (self.keepalive) 1 else 0,
            .name_len = @intCast(self.session_name.len),
        };
        try wire.writeControlWithTrail(fd, .register, std.mem.asBytes(&reg), self.session_name);

        // Wait for registered response.
        const hdr = try self.readSyncResponse(fd);
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (msg_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.RegistrationFailed;
        }
        if (msg_type != .registered) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }
        self.skipPayload(fd, hdr.payload_len);
    }

    /// Update session info and re-register with ses (used after reattach).
    pub fn updateSession(self: *SesClient, session_id: [32]u8, session_name: []const u8) !void {
        self.session_id = session_id;
        self.session_name = session_name;
        try self.register();
    }

    /// Tell ses this mux is exiting normally.
    pub fn shutdown(self: *SesClient, preserve_sticky: bool) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.Disconnect = .{
            .mode = 0, // shutdown
            .preserve_sticky = if (preserve_sticky) 1 else 0,
        };
        // Best-effort: don't block on a reply.
        wire.writeControl(fd, .disconnect, std.mem.asBytes(&msg)) catch {};
    }

    /// Sync current mux state to ses (fire-and-forget).
    pub fn syncState(self: *SesClient, mux_state_json: []const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SyncState = .{
            .state_len = @intCast(mux_state_json.len),
        };
        try wire.writeControlWithTrail(fd, .sync_state, std.mem.asBytes(&msg), mux_state_json);
    }

    /// Create a new pane via ses.
    /// Returns the pane UUID, pane_id (for VT routing), and pod PID.
    pub fn createPane(
        self: *SesClient,
        shell: ?[]const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
        _: ?[]const []const u8, // env (unused in binary protocol — pod inherits)
        _: ?[]const []const u8, // extra_env (unused)
    ) !struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;

        const shell_bytes = shell orelse "";
        const cwd_bytes = cwd orelse "";
        const sticky_pwd_bytes = sticky_pwd orelse "";

        var msg: wire.CreatePane = .{
            .shell_len = @intCast(shell_bytes.len),
            .cwd_len = @intCast(cwd_bytes.len),
            .sticky_key = sticky_key orelse 0,
            .sticky_pwd_len = @intCast(sticky_pwd_bytes.len),
        };
        const trails: []const []const u8 = &.{ shell_bytes, cwd_bytes, sticky_pwd_bytes };
        mux.debugLog("createPane: shell={s} cwd={s}", .{ shell_bytes, cwd_bytes });
        try wire.writeControlMsg(fd, .create_pane, std.mem.asBytes(&msg), trails);

        // Read response.
        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.SesError;
        }
        if (resp_type != .pane_created) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.PaneCreated, fd);
        // Skip socket_path (we don't need it — VT goes through SES).
        if (resp.socket_len > 0) {
            var skip_buf: [512]u8 = undefined;
            wire.readExact(fd, skip_buf[0..resp.socket_len]) catch {};
        }

        mux.debugLog("pane created: uuid={s} pane_id={d} pid={d}", .{ resp.uuid[0..8], resp.pane_id, resp.pid });
        return .{
            .uuid = resp.uuid,
            .pane_id = resp.pane_id,
            .pid = resp.pid,
        };
    }

    /// Find a sticky pane (for pwd floats).
    pub fn findStickyPane(self: *SesClient, pwd: []const u8, key: u8) !?struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;

        var msg: wire.FindSticky = .{
            .key = key,
            .pwd_len = @intCast(pwd.len),
        };
        try wire.writeControlWithTrail(fd, .find_sticky, std.mem.asBytes(&msg), pwd);

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .pane_not_found) {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        if (resp_type != .pane_found) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.PaneFound, fd);
        // Skip socket_path.
        if (resp.socket_len > 0) {
            var skip_buf: [512]u8 = undefined;
            wire.readExact(fd, skip_buf[0..@min(@as(usize, resp.socket_len), skip_buf.len)]) catch {};
        }

        return .{ .uuid = resp.uuid, .pane_id = resp.pane_id, .pid = resp.pid };
    }

    /// Orphan a pane (manual suspend).
    pub fn orphanPane(self: *SesClient, uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        try wire.writeControl(fd, .orphan_pane, std.mem.asBytes(&msg));
    }

    /// Set sticky info on a pane.
    pub fn setSticky(self: *SesClient, uuid: [32]u8, pwd: []const u8, key: u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.SetSticky = .{
            .uuid = uuid,
            .key = key,
            .pwd_len = @intCast(pwd.len),
        };
        try wire.writeControlWithTrail(fd, .set_sticky, std.mem.asBytes(&msg), pwd);
    }

    /// Kill a pane.
    pub fn killPane(self: *SesClient, uuid: [32]u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        try wire.writeControl(fd, .kill_pane, std.mem.asBytes(&msg));
    }

    /// Request pane CWD from ses (fire-and-forget; response handled in handleSesMessage).
    pub fn requestPaneCwd(self: *SesClient, uuid: [32]u8) void {
        const fd = self.ctl_fd orelse return;
        self.pending_cwd_uuid = uuid;
        var msg: wire.GetPaneCwd = .{ .uuid = uuid };
        wire.writeControl(fd, .get_pane_cwd, std.mem.asBytes(&msg)) catch return;
    }

    /// Ping ses to check if it's alive.
    pub fn ping(self: *SesClient) !bool {
        const fd = self.ctl_fd orelse return false;
        try wire.writeControl(fd, .ping, &.{});

        const hdr = self.readSyncResponse(fd) catch return false;
        self.skipPayload(fd, hdr.payload_len);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        return resp_type == .pong;
    }

    /// Update pane name in ses (fire-and-forget).
    pub fn updatePaneName(self: *SesClient, uuid: [32]u8, name: ?[]const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const name_bytes = name orelse "";
        var msg: wire.UpdatePaneName = .{
            .uuid = uuid,
            .name_len = @intCast(name_bytes.len),
        };
        try wire.writeControlWithTrail(fd, .update_pane_name, std.mem.asBytes(&msg), name_bytes);
    }

    /// Update shell-provided pane metadata (fire-and-forget).
    pub fn updatePaneShell(self: *SesClient, uuid: [32]u8, cmd: ?[]const u8, cwd: ?[]const u8, status: ?i32, duration_ms: ?u64, jobs: ?u16) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;
        const cmd_bytes = cmd orelse "";
        const cwd_bytes = cwd orelse "";
        var msg: wire.UpdatePaneShell = .{
            .uuid = uuid,
            .status = status orelse 0,
            .has_status = if (status != null) 1 else 0,
            .duration_ms = if (duration_ms) |d| @intCast(d) else 0,
            .has_duration = if (duration_ms != null) 1 else 0,
            .jobs = jobs orelse 0,
            .has_jobs = if (jobs != null) 1 else 0,
            .cmd_len = @intCast(cmd_bytes.len),
            .cwd_len = @intCast(cwd_bytes.len),
        };
        const trails: []const []const u8 = &.{ cmd_bytes, cwd_bytes };
        try wire.writeControlMsg(fd, .update_pane_shell, std.mem.asBytes(&msg), trails);
    }

    /// Pane type enum for auxiliary info.
    pub const PaneType = enum { split, float };
    pub const PaneAuxInfo = struct { created_from: ?[32]u8, focused_from: ?[32]u8 };
    pub const PaneProcessInfo = struct { name: ?[]u8 = null, pid: ?i32 = null };

    /// Update auxiliary pane info (synced from mux to ses).
    /// In binary protocol, pane_info is tracked by SES via POD reports.
    /// This is a best-effort no-op now (SES ignores update_pane_aux).
    pub fn updatePaneAux(
        self: *SesClient,
        _: [32]u8,
        _: bool,
        _: bool,
        _: PaneType,
        _: ?[32]u8,
        _: ?[32]u8,
        _: ?struct { x: u16, y: u16 },
        _: ?u8,
        _: ?bool,
        _: ?bool,
        _: ?struct { cols: u16, rows: u16 },
        _: ?[]const u8,
        _: ?[]const u8,
        _: ?posix.pid_t,
        _: ?[]const u8,
    ) !void {
        _ = self;
        // No-op in binary protocol — SES tracks pane state from POD.
    }

    /// Get auxiliary pane info — no-op in binary protocol (SES tracks via POD).
    pub fn getPaneAux(_: *SesClient, _: [32]u8) !PaneAuxInfo {
        return .{ .created_from = null, .focused_from = null };
    }

    /// Request foreground process info for a pane (fire-and-forget; response handled in handleSesMessage).
    pub fn requestPaneProcess(self: *SesClient, uuid: [32]u8) void {
        const fd = self.ctl_fd orelse return;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        wire.writeControl(fd, .pane_info, std.mem.asBytes(&msg)) catch return;
    }

    /// Best-effort pane name (sync call, skips pending .ok/.get_pane_cwd responses).
    pub fn getPaneName(self: *SesClient, uuid: [32]u8) ?[]u8 {
        const fd = self.ctl_fd orelse return null;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        wire.writeControl(fd, .pane_info, std.mem.asBytes(&msg)) catch return null;

        // Read response, skipping fire-and-forget acks (but NOT .pane_info).
        const hdr = blk: {
            while (true) {
                const h = wire.readControlHeader(fd) catch return null;
                const mt: wire.MsgType = @enumFromInt(h.msg_type);
                if (mt == .ok or mt == .get_pane_cwd) {
                    self.skipPayload(fd, h.payload_len);
                    continue;
                }
                break :blk h;
            }
        };
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        const resp = wire.readStruct(wire.PaneInfoResp, fd) catch return null;
        var result: ?[]u8 = null;

        // Calculate total trailing bytes.
        const trail_total: usize = @as(usize, resp.name_len) + @as(usize, resp.fg_len) +
            @as(usize, resp.cwd_len) + @as(usize, resp.tty_len) +
            @as(usize, resp.socket_path_len) + @as(usize, resp.session_name_len) +
            @as(usize, resp.layout_path_len) + @as(usize, resp.last_cmd_len) +
            @as(usize, resp.base_process_len) + @as(usize, resp.sticky_pwd_len);

        if (resp.name_len > 0) {
            const buf = self.allocator.alloc(u8, resp.name_len) catch {
                self.skipPayload(fd, @intCast(trail_total));
                return null;
            };
            wire.readExact(fd, buf) catch {
                self.allocator.free(buf);
                return null;
            };
            result = buf;
        }
        // Skip all remaining trailing bytes.
        const remaining = trail_total - @as(usize, resp.name_len);
        if (remaining > 0) {
            self.skipPayload(fd, @intCast(remaining));
        }
        return result;
    }

    /// Adopt an orphaned pane.
    pub fn adoptPane(self: *SesClient, uuid: [32]u8) !struct { uuid: [32]u8, pane_id: u16, pid: posix.pid_t } {
        const fd = self.ctl_fd orelse return error.NotConnected;
        var msg: wire.PaneUuid = .{ .uuid = uuid };
        try wire.writeControl(fd, .adopt_pane, std.mem.asBytes(&msg));

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.SesError;
        }
        if (resp_type != .pane_found) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.PaneFound, fd);
        if (resp.socket_len > 0) {
            var skip_buf: [512]u8 = undefined;
            wire.readExact(fd, skip_buf[0..@min(@as(usize, resp.socket_len), skip_buf.len)]) catch {};
        }
        return .{ .uuid = uuid, .pane_id = resp.pane_id, .pid = resp.pid };
    }

    /// List orphaned panes.
    pub fn listOrphanedPanes(self: *SesClient, out_buf: []OrphanedPaneInfo) !usize {
        const fd = self.ctl_fd orelse return error.NotConnected;
        try wire.writeControl(fd, .list_orphaned, &.{});

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .orphaned_panes) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.OrphanedPanes, fd);
        var count: usize = 0;
        for (0..resp.pane_count) |_| {
            const entry = wire.readStruct(wire.OrphanedPaneEntry, fd) catch break;
            if (count < out_buf.len) {
                out_buf[count] = .{ .uuid = entry.uuid, .pid = entry.pid };
                count += 1;
            }
        }
        return count;
    }

    /// Detach session — keeps panes grouped for later reattach.
    pub fn detachSession(self: *SesClient, session_id: [32]u8, mux_state_json: []const u8) !void {
        const fd = self.ctl_fd orelse return error.NotConnected;

        // Convert 32-char hex session_id to 16 binary bytes for the struct.
        var msg: wire.Detach = .{
            .session_id = session_id,
            .state_len = @intCast(mux_state_json.len),
        };
        try wire.writeControlWithTrail(fd, .detach, std.mem.asBytes(&msg), mux_state_json);

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return error.DetachFailed;
        }
        self.skipPayload(fd, hdr.payload_len);
    }

    /// Result of reattaching a session.
    pub const ReattachResult = struct {
        mux_state_json: []const u8, // Owned — caller must free
        pane_uuids: [][32]u8, // Owned — caller must free
    };

    /// Reattach to a detached session.
    pub fn reattachSession(self: *SesClient, session_id: []const u8) !?ReattachResult {
        const fd = self.ctl_fd orelse return error.NotConnected;

        var msg: wire.Reattach = .{
            .id_len = @intCast(session_id.len),
        };
        try wire.writeControlWithTrail(fd, .reattach, std.mem.asBytes(&msg), session_id);

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type == .@"error") {
            self.skipPayload(fd, hdr.payload_len);
            return null;
        }
        if (resp_type != .session_reattached) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.SessionReattached, fd);

        // Read mux_state_json.
        const mux_state = self.allocator.alloc(u8, resp.state_len) catch return error.OutOfMemory;
        errdefer self.allocator.free(mux_state);
        try wire.readExact(fd, mux_state);

        // Read pane UUIDs (each 32 bytes).
        var pane_uuids = self.allocator.alloc([32]u8, resp.pane_count) catch return error.OutOfMemory;
        errdefer self.allocator.free(pane_uuids);
        for (0..resp.pane_count) |i| {
            try wire.readExact(fd, &pane_uuids[i]);
        }

        return .{
            .mux_state_json = mux_state,
            .pane_uuids = pane_uuids,
        };
    }

    /// List detached sessions.
    pub fn listSessions(self: *SesClient, out_buf: []DetachedSessionInfo) !usize {
        const fd = self.ctl_fd orelse return error.NotConnected;
        try wire.writeControl(fd, .list_sessions, &.{});

        const hdr = try self.readSyncResponse(fd);
        const resp_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        if (resp_type != .sessions_list) {
            self.skipPayload(fd, hdr.payload_len);
            return error.UnexpectedResponse;
        }

        const resp = try wire.readStruct(wire.SessionsList, fd);
        var count: usize = 0;
        for (0..resp.session_count) |_| {
            const entry = wire.readStruct(wire.SessionEntry, fd) catch break;
            var info: DetachedSessionInfo = undefined;
            info.session_id = entry.session_id;
            info.pane_count = entry.pane_count;
            // Read name.
            const name_len = @min(@as(usize, entry.name_len), 32);
            if (entry.name_len > 0) {
                var name_buf: [32]u8 = undefined;
                wire.readExact(fd, name_buf[0..name_len]) catch break;
                @memcpy(info.session_name[0..name_len], name_buf[0..name_len]);
                info.session_name_len = name_len;
                // Skip excess name bytes.
                if (entry.name_len > 32) {
                    self.skipPayloadU16(fd, entry.name_len - 32);
                }
            } else {
                info.session_name_len = 0;
            }
            if (count < out_buf.len) {
                out_buf[count] = info;
                count += 1;
            }
        }
        return count;
    }

    /// Start the ses daemon.
    fn startSes(self: *SesClient) !void {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);

        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        try args_list.append(self.allocator, exe_path);
        try args_list.append(self.allocator, "ses");
        try args_list.append(self.allocator, "daemon");

        if (std.posix.getenv("HEXE_INSTANCE")) |inst| {
            if (inst.len > 0) {
                try args_list.append(self.allocator, "--instance");
                try args_list.append(self.allocator, inst);
            }
        }
        if (std.posix.getenv("HEXE_TEST_ONLY")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                try args_list.append(self.allocator, "--test-only");
            }
        }
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
        _ = child.wait() catch {};
    }

    /// Check if connected to ses.
    pub fn isConnected(self: *SesClient) bool {
        return self.ctl_fd != null;
    }

    /// Get the VT channel fd (for polling in the event loop).
    pub fn getVtFd(self: *SesClient) ?posix.fd_t {
        return self.vt_fd;
    }

    /// Get the control channel fd (for polling async messages).
    pub fn getCtlFd(self: *SesClient) ?posix.fd_t {
        return self.ctl_fd;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Read a response from the CTL fd, skipping any fire-and-forget response
    /// types that may have arrived before our expected response.
    fn readSyncResponse(self: *SesClient, fd: posix.fd_t) !wire.ControlHeader {
        while (true) {
            const hdr = try wire.readControlHeader(fd);
            const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
            switch (msg_type) {
                // Fire-and-forget acks from syncState/updatePaneName/updatePaneShell.
                .ok => {
                    self.skipPayload(fd, hdr.payload_len);
                    continue;
                },
                // Async get_pane_cwd response.
                .get_pane_cwd => {
                    self.skipPayload(fd, hdr.payload_len);
                    continue;
                },
                // Async pane_info response (large payload = response, not request).
                .pane_info => {
                    if (hdr.payload_len >= @sizeOf(wire.PaneInfoResp)) {
                        self.skipPayload(fd, hdr.payload_len);
                        continue;
                    }
                    return hdr;
                },
                else => return hdr,
            }
        }
    }

    fn skipPayload(self: *SesClient, fd: posix.fd_t, len: u32) void {
        _ = self;
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
    }

    fn skipPayloadU16(_: *SesClient, fd: posix.fd_t, len: u16) void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
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
