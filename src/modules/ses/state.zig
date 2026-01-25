const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const ses = @import("main.zig");

/// Pane state - minimal, just keeps process alive
pub const PaneState = enum {
    attached, // mux is connected and owns this pane
    detached, // part of detached session, waiting for reattach
    sticky, // sticky pwd float, waiting for same pwd+key
    orphaned, // fully orphaned, any mux can adopt
};

/// Pane type - split or float
pub const PaneType = enum {
    split,
    float,
};

/// Minimal pane structure - just what's needed to keep process alive
pub const Pane = struct {
    uuid: [32]u8,
    name: ?[]const u8 = null,
    pod_pid: posix.pid_t,
    pod_socket_path: []const u8,
    child_pid: posix.pid_t,
    state: PaneState,

    // Binary protocol fields (Phase 3+4)
    pane_id: u16 = 0,
    pod_vt_fd: ?posix.fd_t = null,
    pod_ctl_fd: ?posix.fd_t = null,

    // For sticky pwd floats
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,

    // Which client owns this pane (null if orphaned/detached)
    attached_to: ?usize,

    // Session ID for detached panes (so they can be reattached together)
    session_id: ?[16]u8,

    // Timestamps
    created_at: i64,
    orphaned_at: ?i64,

    // Auxiliary info (synced from mux)
    is_float: bool = false,
    is_focused: bool = false,
    pane_type: PaneType = .split,
    created_from: ?[32]u8 = null,
    focused_from: ?[32]u8 = null,
    // Cursor position (synced from mux, screen coordinates)
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    // Cursor style and visibility (synced from mux)
    cursor_style: u8 = 0,
    cursor_visible: bool = true,
    // Alt screen state (synced from mux)
    alt_screen: bool = false,
    // Pane window size (synced from mux)
    cols: u16 = 0,
    rows: u16 = 0,
    // Current working directory (synced from mux, owned)
    cwd: ?[]const u8 = null,
    // Foreground process info (synced from mux)
    fg_process: ?[]const u8 = null,
    fg_pid: ?i32 = null,
    // Layout path (synced from mux, owned)
    layout_path: ?[]const u8 = null,

    // Shell-provided metadata (owned)
    last_cmd: ?[]const u8 = null,
    last_status: ?i32 = null,
    last_duration_ms: ?u64 = null,
    last_jobs: ?u16 = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Pane) void {
        if (self.name) |n| {
            self.allocator.free(n);
        }
        self.allocator.free(self.pod_socket_path);
        if (self.sticky_pwd) |pwd| {
            self.allocator.free(pwd);
        }
        if (self.cwd) |c| {
            self.allocator.free(c);
        }
        if (self.fg_process) |p| {
            self.allocator.free(p);
        }
        if (self.layout_path) |path| {
            self.allocator.free(path);
        }
        if (self.last_cmd) |c| {
            self.allocator.free(c);
        }
    }

    // Static buffer for getProcCwd to avoid returning dangling pointer
    var proc_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var proc_comm_buf: [128]u8 = undefined;
    var proc_stat_buf: [512]u8 = undefined;
    var proc_tty_buf: [std.fs.max_path_bytes]u8 = undefined;

    /// Get current working directory from /proc/<child_pid>/cwd
    /// This is the authoritative CWD from OS, not dependent on shell OSC 7
    pub fn getProcCwd(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{self.child_pid}) catch return null;
        const link = posix.readlink(path, &proc_cwd_buf) catch return null;
        return link;
    }

    fn readProcComm(self: *const Pane, pid: i32) ?[]const u8 {
        _ = self;
        if (pid <= 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const len = file.read(&proc_comm_buf) catch return null;
        if (len == 0) return null;
        const end = if (proc_comm_buf[len - 1] == '\n') len - 1 else len;
        return proc_comm_buf[0..end];
    }

    /// Get process name from /proc/<child_pid>/comm.
    pub fn getProcProcessName(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;
        return self.readProcComm(@intCast(self.child_pid));
    }

    /// Get foreground process group PID from /proc/<child_pid>/stat.
    pub fn getProcForegroundPid(self: *const Pane) ?i32 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{self.child_pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();

        const len = file.read(&proc_stat_buf) catch return null;
        if (len == 0) return null;
        const stat = proc_stat_buf[0..len];

        const right_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
        if (right_paren + 2 >= stat.len) return null;
        const rest = stat[right_paren + 2 ..];

        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        var idx: usize = 0;
        while (it.next()) |tok| {
            idx += 1;
            if (idx == 6) {
                const tpgid = std.fmt.parseInt(i32, tok, 10) catch return null;
                if (tpgid <= 0) return null;
                return tpgid;
            }
        }

        return null;
    }

    pub fn getProcForegroundProcess(self: *const Pane) ?struct { name: []const u8, pid: i32 } {
        const fg_pid = self.getProcForegroundPid() orelse return null;
        const name = self.readProcComm(fg_pid) orelse return null;
        return .{ .name = name, .pid = fg_pid };
    }

    /// Get controlling TTY path from /proc/<child_pid>/fd/0.
    pub fn getProcTty(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/fd/0", .{self.child_pid}) catch return null;
        const link = posix.readlink(path, &proc_tty_buf) catch return null;
        return link;
    }
};

/// Client connection state
pub const Client = struct {
    id: usize,
    fd: posix.fd_t,
    pane_uuids: std.ArrayList([32]u8),
    allocator: std.mem.Allocator,

    // Keepalive settings
    keepalive: bool,
    session_id: ?[16]u8, // mux's UUID for this client
    session_name: ?[]const u8, // Pokemon name for this session
    last_mux_state: ?[]const u8, // most recent synced state for crash recovery

    // Binary protocol channels (Phase 3+4)
    mux_ctl_fd: ?posix.fd_t = null,
    mux_vt_fd: ?posix.fd_t = null,

    /// Last accepted state sync version. Used to reject stale/out-of-order updates.
    last_sync_version: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, id: usize, fd: posix.fd_t) Client {
        return .{
            .id = id,
            .fd = fd,
            .pane_uuids = .empty,
            .allocator = allocator,
            .keepalive = true, // default to keepalive
            .session_id = null,
            .session_name = null,
            .last_mux_state = null,
        };
    }

    pub fn deinit(self: *Client) void {
        self.pane_uuids.deinit(self.allocator);
        if (self.session_name) |name| {
            self.allocator.free(name);
        }
        if (self.last_mux_state) |state| {
            self.allocator.free(state);
        }
    }

    pub fn appendUuid(self: *Client, uuid: [32]u8) !void {
        try self.pane_uuids.append(self.allocator, uuid);
    }

    pub fn updateMuxState(self: *Client, mux_state: []const u8) !void {
        // Free old state if exists
        if (self.last_mux_state) |old| {
            self.allocator.free(old);
        }
        // Store new state
        self.last_mux_state = try self.allocator.dupe(u8, mux_state);
    }
};

/// Detached session info (for listing)
pub const DetachedSession = struct {
    session_id: [16]u8,
    session_name: []const u8,
    pane_count: usize,
};

/// Full detached mux state - stores the entire layout for reattachment
pub const DetachedMuxState = struct {
    session_id: [16]u8,
    session_name: []const u8, // Pokemon name
    mux_state_json: []const u8, // Full serialized mux state
    pane_uuids: [][32]u8, // List of pane UUIDs in this session
    detached_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DetachedMuxState) void {
        self.allocator.free(self.session_name);
        self.allocator.free(self.mux_state_json);
        self.allocator.free(self.pane_uuids);
    }
};

/// Main ses state - the PTY holder
/// Note: Uses page_allocator internally to avoid GPA issues after fork/daemonization
pub const SesState = struct {
    allocator: std.mem.Allocator,
    panes: std.AutoHashMap([32]u8, Pane),
    clients: std.ArrayList(Client),
    detached_sessions: std.AutoHashMap([16]u8, DetachedMuxState),
    next_client_id: usize,
    orphan_timeout_hours: u32,
    dirty: bool,

    // Binary protocol state (Phase 3+4)
    next_pane_id: u16 = 1,
    pane_id_to_pod_vt: std.AutoHashMap(u16, posix.fd_t),
    pod_vt_to_pane_id: std.AutoHashMap(posix.fd_t, u16),
    /// Fds that need to be added to the server poll set (populated by connectPodVt).
    pending_poll_fds: std.ArrayList(posix.fd_t),

    pub fn init(_: std.mem.Allocator) SesState {
        // Always use page_allocator to avoid GPA issues after fork/daemonization
        const page_alloc = std.heap.page_allocator;
        return .{
            .allocator = page_alloc,
            .panes = std.AutoHashMap([32]u8, Pane).init(page_alloc),
            .clients = .empty,
            .detached_sessions = std.AutoHashMap([16]u8, DetachedMuxState).init(page_alloc),
            .next_client_id = 1,
            .orphan_timeout_hours = 24,
            .dirty = false,
            .pane_id_to_pod_vt = std.AutoHashMap(u16, posix.fd_t).init(page_alloc),
            .pod_vt_to_pane_id = std.AutoHashMap(posix.fd_t, u16).init(page_alloc),
            .pending_poll_fds = .empty,
        };
    }

    pub fn allocPaneId(self: *SesState) u16 {
        const id = self.next_pane_id;
        self.next_pane_id +%= 1;
        if (self.next_pane_id == 0) self.next_pane_id = 1;
        return id;
    }

    /// Connect the VT data channel (③) to a POD socket.
    /// On success, stores the fd in the pane and populates routing tables.
    pub fn connectPodVt(self: *SesState, uuid: [32]u8, pod_socket_path: []const u8, pane_id: u16) void {
        const client = core.ipc.Client.connect(pod_socket_path) catch {
            ses.debugLog("connectPodVt: failed to connect to {s}", .{pod_socket_path});
            return;
        };
        const fd = client.fd;

        // Send versioned handshake.
        wire.sendHandshake(fd, wire.POD_HANDSHAKE_SES_VT) catch {
            posix.close(fd);
            return;
        };

        // Wait for acknowledgment from POD to avoid race during init.
        const ack_hdr = wire.readControlHeader(fd) catch {
            posix.close(fd);
            return;
        };
        const ack_type: wire.MsgType = @enumFromInt(ack_hdr.msg_type);
        if (ack_type != .ok) {
            ses.debugLog("connectPodVt: unexpected ack {x}, closing", .{ack_hdr.msg_type});
            posix.close(fd);
            return;
        }

        // Store in pane.
        if (self.panes.getPtr(uuid)) |pane| {
            if (pane.pod_vt_fd) |old_fd| {
                _ = self.pod_vt_to_pane_id.remove(old_fd);
                posix.close(old_fd);
            }
            pane.pod_vt_fd = fd;
        }

        // Populate routing tables.
        self.pane_id_to_pod_vt.put(pane_id, fd) catch {};
        self.pod_vt_to_pane_id.put(fd, pane_id) catch {};

        // Queue fd for poll set addition by the server loop.
        self.pending_poll_fds.append(self.allocator, fd) catch {};

        ses.debugLog("connectPodVt: pane_id={d} fd={d}", .{ pane_id, fd });
    }

    pub fn markDirty(self: *SesState) void {
        self.dirty = true;
    }

    pub fn deinit(self: *SesState) void {
        // Close all panes
        var pane_iter = self.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            // ses is registry-only; do not kill pods on shutdown.
            var p = pane;
            if (p.pod_vt_fd) |fd| posix.close(fd);
            if (p.pod_ctl_fd) |fd| posix.close(fd);
            p.deinit();
        }
        self.panes.deinit();

        // Cleanup detached sessions
        var sess_iter = self.detached_sessions.valueIterator();
        while (sess_iter.next()) |sess| {
            var s = sess;
            s.deinit();
        }
        self.detached_sessions.deinit();

        // Cleanup clients
        for (self.clients.items) |*client| {
            if (client.mux_ctl_fd) |fd| posix.close(fd);
            if (client.mux_vt_fd) |fd| posix.close(fd);
            client.deinit();
        }
        self.clients.deinit(self.allocator);

        self.pane_id_to_pod_vt.deinit();
        self.pod_vt_to_pane_id.deinit();
    }

    /// Add a new client connection
    pub fn addClient(self: *SesState, fd: posix.fd_t) !usize {
        const id = self.next_client_id;
        self.next_client_id += 1;

        try self.clients.append(self.allocator, Client.init(self.allocator, id, fd));
        return id;
    }

    /// Remove a client - behavior depends on keepalive setting
    /// keepalive=true: auto-detach session (preserve for reattach)
    /// keepalive=false: kill all panes
    pub fn removeClient(self: *SesState, client_id: usize) void {
        // Find and remove client
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                if (client.keepalive) {
                    // Auto-detach: preserve session with last known state
                    if (client.session_id) |session_id| {
                        const mux_state = client.last_mux_state orelse "{}";
                        // Use detachSessionDirect to avoid removing client twice
                        self.detachSessionDirect(client, session_id, mux_state);
                    } else {
                        // No session_id yet, just kill panes
                        for (client.pane_uuids.items) |uuid| {
                            self.killPane(uuid) catch |e| {
                                core.logging.logError("ses", "killPane failed in removeClient", e);
                            };
                        }
                    }
                } else {
                    // No keepalive: kill all panes
                    for (client.pane_uuids.items) |uuid| {
                        self.killPane(uuid) catch |e| {
                            core.logging.logError("ses", "killPane failed in removeClient", e);
                        };
                    }
                }
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        }
    }

    /// Remove a client gracefully - mux already handled cleanup, no auto-detach.
    pub fn removeClientGraceful(self: *SesState, client_id: usize) void {
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        }
    }

    /// Shutdown a client (normal mux exit):
    /// - optionally preserve sticky panes
    /// - kill everything else
    /// - remove client without creating a detached session
    pub fn shutdownClient(self: *SesState, client_id: usize, preserve_sticky: bool) void {
        var client_index: ?usize = null;
        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                for (client.pane_uuids.items) |uuid| {
                    if (preserve_sticky) {
                        if (self.panes.getPtr(uuid)) |pane| {
                            if (pane.sticky_pwd != null and pane.sticky_key != null) {
                                pane.state = .sticky;
                                pane.attached_to = null;
                                pane.orphaned_at = std.time.timestamp();
                                continue;
                            }
                        }
                    }
                    self.killPane(uuid) catch |e| {
                        core.logging.logError("ses", "killPane failed in shutdownClient", e);
                    };
                }

                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);
        }
        self.dirty = true;
    }

    /// Internal: detach session without removing client (used by removeClient)
    fn detachSessionDirect(self: *SesState, client: *Client, session_id: [16]u8, mux_state_json: []const u8) void {
        var pane_uuids_list: std.ArrayList([32]u8) = .empty;

        // Mark all panes as detached and collect UUIDs
        for (client.pane_uuids.items) |uuid| {
            if (self.panes.getPtr(uuid)) |pane| {
                pane.state = .detached;
                pane.session_id = session_id;
                pane.attached_to = null;
                pane_uuids_list.append(self.allocator, uuid) catch continue;
            }
        }

        // If session already exists (re-detach), remove old state first
        if (self.detached_sessions.fetchRemove(session_id)) |old| {
            var old_state = old.value;
            old_state.deinit();
        }

        // Store the full mux state
        const owned_name = self.allocator.dupe(u8, client.session_name orelse "unknown") catch {
            pane_uuids_list.deinit(self.allocator);
            return;
        };
        const owned_json = self.allocator.dupe(u8, mux_state_json) catch {
            self.allocator.free(owned_name);
            pane_uuids_list.deinit(self.allocator);
            return;
        };
        const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
            self.allocator.free(owned_name);
            self.allocator.free(owned_json);
            return;
        };

        const detached_state = DetachedMuxState{
            .session_id = session_id,
            .session_name = owned_name,
            .mux_state_json = owned_json,
            .pane_uuids = owned_uuids,
            .detached_at = std.time.timestamp(),
            .allocator = self.allocator,
        };

        self.detached_sessions.put(session_id, detached_state) catch {
            self.allocator.free(owned_name);
            self.allocator.free(owned_json);
            self.allocator.free(owned_uuids);
        };
        self.dirty = true;
    }

    /// Detach a client's session with a specific session ID (mux's UUID)
    /// Stores the full mux state for later restoration
    /// If the session already exists (re-detach), it updates the existing state
    /// Returns true on success, false if client not found
    pub fn detachSession(self: *SesState, client_id: usize, session_id: [16]u8, session_name: []const u8, mux_state_json: []const u8) bool {
        // Find client
        var client_index: ?usize = null;
        var pane_uuids_list: std.ArrayList([32]u8) = .empty;

        // Dupe session_name BEFORE client.deinit() frees the original
        const owned_name = self.allocator.dupe(u8, session_name) catch return false;
        errdefer self.allocator.free(owned_name);

        for (self.clients.items, 0..) |*client, i| {
            if (client.id == client_id) {
                // Mark all panes as detached with session_id and collect UUIDs
                for (client.pane_uuids.items) |uuid| {
                    if (self.panes.getPtr(uuid)) |pane| {
                        pane.state = .detached;
                        pane.session_id = session_id;
                        pane.attached_to = null;
                        pane_uuids_list.append(self.allocator, uuid) catch continue;
                    }
                }
                client.deinit();
                client_index = i;
                break;
            }
        }

        if (client_index) |idx| {
            _ = self.clients.orderedRemove(idx);

            // If session already exists (re-detach), remove old state first
            if (self.detached_sessions.fetchRemove(session_id)) |old| {
                var old_state = old.value;
                old_state.deinit();
            }

            // Store the full mux state (owned_name already duped above)
            const owned_json = self.allocator.dupe(u8, mux_state_json) catch {
                self.allocator.free(owned_name);
                return true;
            };
            const owned_uuids = pane_uuids_list.toOwnedSlice(self.allocator) catch {
                self.allocator.free(owned_name);
                self.allocator.free(owned_json);
                return true;
            };

            const detached_state = DetachedMuxState{
                .session_id = session_id,
                .session_name = owned_name,
                .mux_state_json = owned_json,
                .pane_uuids = owned_uuids,
                .detached_at = std.time.timestamp(),
                .allocator = self.allocator,
            };

            self.detached_sessions.put(session_id, detached_state) catch {
                self.allocator.free(owned_name);
                self.allocator.free(owned_json);
                self.allocator.free(owned_uuids);
            };
            self.dirty = true;

            return true;
        } else {
            pane_uuids_list.deinit(self.allocator);
            self.allocator.free(owned_name);
        }
        return false;
    }

    /// Result of reattaching a session
    pub const ReattachResult = struct {
        mux_state_json: []const u8, // The full mux state to restore
        pane_uuids: [][32]u8, // UUIDs of panes to adopt
    };

    /// Reattach to a detached session - returns mux state and pane UUIDs
    /// Note: Panes remain in "detached" state until adoptPane is called for each
    pub fn reattachSession(self: *SesState, session_id: [16]u8, client_id: usize) !?ReattachResult {
        _ = client_id; // Client will adopt panes individually

        // Find the detached session
        const detached = self.detached_sessions.fetchRemove(session_id) orelse return null;
        const detached_state = detached.value;
        self.dirty = true;

        // Clear session_id from panes (they're no longer part of a detached session)
        // But keep them as "detached" state - adoptPane will mark them as attached
        for (detached_state.pane_uuids) |uuid| {
            if (self.panes.getPtr(uuid)) |pane| {
                pane.session_id = null;
            }
        }

        // Return the stored state (caller takes ownership)
        return .{
            .mux_state_json = detached_state.mux_state_json,
            .pane_uuids = detached_state.pane_uuids,
        };
    }

    /// List detached sessions
    pub fn listDetachedSessions(self: *SesState, allocator: std.mem.Allocator) ![]DetachedSession {
        var result: std.ArrayList(DetachedSession) = .empty;
        errdefer result.deinit(allocator);

        var iter = self.detached_sessions.valueIterator();
        while (iter.next()) |detached| {
            try result.append(allocator, .{
                .session_id = detached.session_id,
                .session_name = detached.session_name,
                .pane_count = detached.pane_uuids.len,
            });
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get client by ID
    pub fn getClient(self: *SesState, client_id: usize) ?*Client {
        for (self.clients.items) |*client| {
            if (client.id == client_id) return client;
        }
        return null;
    }

    /// Orphan a pane (either half or full depending on sticky)
    fn orphanPane(self: *SesState, pane: *Pane) void {
        _ = self;
        const now = std.time.timestamp();

        if (pane.sticky_pwd != null and pane.sticky_key != null) {
            // Sticky pwd float - becomes half-orphaned
            pane.state = .sticky;
        } else {
            // Regular pane - becomes fully orphaned
            pane.state = .orphaned;
        }

        pane.attached_to = null;
        pane.orphaned_at = now;
    }

    /// Create a new pane by spawning a per-pane pod process.
    pub fn createPane(
        self: *SesState,
        client_id: usize,
        shell: []const u8,
        cwd: ?[]const u8,
        sticky_pwd: ?[]const u8,
        sticky_key: ?u8,
        env: ?[]const []const u8,
        extra_env: ?[]const []const u8,
    ) !*Pane {
        const uuid = ipc.generateUuid();
        const base_name = ipc.generatePaneName();
        const name = try self.generateUniquePaneName(base_name);
        errdefer self.allocator.free(name);
        const pod_socket_path = try ipc.getPodSocketPath(self.allocator, &uuid);
        errdefer self.allocator.free(pod_socket_path);

        const spawn = try self.spawnPod(uuid, name, pod_socket_path, shell, cwd, env, extra_env);

        // Copy sticky_pwd if provided
        const owned_pwd: ?[]const u8 = if (sticky_pwd) |pwd|
            try self.allocator.dupe(u8, pwd)
        else
            null;

        const now = std.time.timestamp();

        const pane_id = self.allocPaneId();

        const pane = Pane{
            .uuid = uuid,
            .name = name,
            .pod_pid = spawn.pod_pid,
            .pod_socket_path = pod_socket_path,
            .child_pid = spawn.child_pid,
            .state = .attached,
            .sticky_pwd = owned_pwd,
            .sticky_key = sticky_key,
            .attached_to = client_id,
            .session_id = null,
            .created_at = now,
            .orphaned_at = null,
            .pane_id = pane_id,
            .allocator = self.allocator,
        };

        try self.panes.put(uuid, pane);
        self.dirty = true;

        // Connect VT channel (③) to POD — best-effort.
        self.connectPodVt(uuid, pod_socket_path, pane_id);

        // Add to client's pane list
        if (self.getClient(client_id)) |client| {
            try client.appendUuid(uuid);
        }

        return self.panes.getPtr(uuid).?;
    }

    fn generateUniquePaneName(self: *SesState, base: []const u8) ![]const u8 {
        // Names are per-ses daemon, so keep them unique among all panes we track.
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const candidate = if (attempt == 0)
                try self.allocator.dupe(u8, base)
            else
                try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base, attempt + 1 });

            var used = false;
            var it = self.panes.valueIterator();
            while (it.next()) |p| {
                if (p.name) |n| {
                    if (std.mem.eql(u8, n, candidate)) {
                        used = true;
                        break;
                    }
                }
            }

            if (!used) return candidate;
            self.allocator.free(candidate);
        }
    }

    fn spawnPod(
        self: *SesState,
        uuid: [32]u8,
        name: []const u8,
        pod_socket_path: []const u8,
        shell: []const u8,
        cwd: ?[]const u8,
        env: ?[]const []const u8,
        extra_env: ?[]const []const u8,
    ) !struct { pod_pid: posix.pid_t, child_pid: posix.pid_t } {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);

        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        try args_list.append(self.allocator, exe_path);
        try args_list.append(self.allocator, "pod");
        try args_list.append(self.allocator, "daemon");

        // Propagate instance/test-only flags for debugging/clarity.
        // Runtime behavior is primarily controlled by environment (HEXE_INSTANCE).
        if (posix.getenv("HEXE_INSTANCE")) |inst| {
            if (inst.len > 0) {
                try args_list.append(self.allocator, "--instance");
                try args_list.append(self.allocator, inst);
            }
        }
        if (posix.getenv("HEXE_TEST_ONLY")) |v| {
            if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
                try args_list.append(self.allocator, "--test-only");
            }
        }

        try args_list.append(self.allocator, "--uuid");
        try args_list.append(self.allocator, uuid[0..]);
        try args_list.append(self.allocator, "--name");
        try args_list.append(self.allocator, name);
        try args_list.append(self.allocator, "--socket");
        try args_list.append(self.allocator, pod_socket_path);
        try args_list.append(self.allocator, "--shell");
        try args_list.append(self.allocator, shell);
        if (cwd) |dir| {
            try args_list.append(self.allocator, "--cwd");
            try args_list.append(self.allocator, dir);
        }
        if (ses.debug_enabled) {
            try args_list.append(self.allocator, "--debug");
        }
        if (ses.log_file_path) |path| {
            try args_list.append(self.allocator, "--logfile");
            try args_list.append(self.allocator, path);
        }
        try args_list.append(self.allocator, "--foreground");

        var child = std.process.Child.init(args_list.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Pipe;

        var env_map_storage: ?std.process.EnvMap = null;
        defer if (env_map_storage) |*map| map.deinit();

        const instance_env = posix.getenv("HEXE_INSTANCE");
        const test_only_env = posix.getenv("HEXE_TEST_ONLY");
        const needs_runtime_env = (instance_env != null and instance_env.?.len > 0) or (test_only_env != null and test_only_env.?.len > 0);

        if (env != null or extra_env != null or needs_runtime_env) {
            var env_map = if (env == null)
                try std.process.getEnvMap(self.allocator)
            else
                std.process.EnvMap.init(self.allocator);

            if (env) |vars| {
                for (vars) |entry| {
                    const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                    if (sep == 0 or sep + 1 > entry.len) continue;
                    try env_map.put(entry[0..sep], entry[sep + 1 ..]);
                }
            }

            if (extra_env) |vars| {
                for (vars) |entry| {
                    const sep = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
                    if (sep == 0 or sep + 1 > entry.len) continue;
                    try env_map.put(entry[0..sep], entry[sep + 1 ..]);
                }
            }

            // Force instance/test-only values from this ses process.
            // This prevents user-provided env overrides from escaping the instance namespace.
            if (instance_env) |inst| {
                if (inst.len > 0) try env_map.put("HEXE_INSTANCE", inst);
            }
            if (test_only_env) |v| {
                if (v.len > 0) try env_map.put("HEXE_TEST_ONLY", v);
            }

            env_map_storage = env_map;
            child.env_map = &env_map_storage.?;
        }

        try child.spawn();
        const pod_pid: posix.pid_t = @intCast(child.id);

        var stdout_file = child.stdout orelse return error.PodNoStdout;
        defer stdout_file.close();

        const spawn_timeout_ms: i64 = 2000;
        const deadline_ms = std.time.milliTimestamp() + spawn_timeout_ms;
        const stdout_fd = stdout_file.handle;

        var line_buf: [512]u8 = undefined;
        var pos: usize = 0;
        while (pos < line_buf.len) {
            const remaining_ms = deadline_ms - std.time.milliTimestamp();
            if (remaining_ms <= 0) return error.PodSpawnTimeout;

            var pfd = [_]posix.pollfd{.{ .fd = stdout_fd, .events = posix.POLL.IN, .revents = 0 }};
            const rc = posix.poll(&pfd, @intCast(remaining_ms)) catch |err| return err;
            if (rc == 0) return error.PodSpawnTimeout;
            if (pfd[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) return error.PodNoHandshake;
            if (pfd[0].revents & posix.POLL.IN == 0) continue;

            var one: [1]u8 = undefined;
            const n = try stdout_file.read(&one);
            if (n == 0) break;
            if (one[0] == '\n') break;
            line_buf[pos] = one[0];
            pos += 1;
        }
        if (pos == 0) return error.PodNoHandshake;
        const line = line_buf[0..pos];

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const pid_val = (root.get("pid") orelse return error.PodBadHandshake).integer;
        const child_pid: posix.pid_t = @intCast(pid_val);

        return .{ .pod_pid = pod_pid, .child_pid = child_pid };
    }

    /// Find a half-orphaned sticky pane matching pwd and key
    pub fn findStickyPane(self: *SesState, pwd: []const u8, key: u8) ?*Pane {
        var iter = self.panes.valueIterator();
        while (iter.next()) |pane| {
            if (pane.state == .sticky) {
                if (pane.sticky_pwd) |spwd| {
                    if (pane.sticky_key) |skey| {
                        if (skey == key and std.mem.eql(u8, spwd, pwd)) {
                            return @constCast(pane);
                        }
                    }
                }
            }
        }
        return null;
    }

    /// Attach an orphaned pane to a client
    pub fn attachPane(self: *SesState, uuid: [32]u8, client_id: usize) !*Pane {
        const pane = self.panes.getPtr(uuid) orelse return error.PaneNotFound;

        if (pane.state == .attached) {
            return error.PaneAlreadyAttached;
        }

        pane.state = .attached;
        pane.attached_to = client_id;
        pane.orphaned_at = null;
        self.dirty = true;

        // Add to client's pane list - fail if client not found
        const client = self.getClient(client_id) orelse return error.ClientNotFound;
        try client.appendUuid(uuid);

        return pane;
    }

    /// Manually orphan a pane (user requested suspend)
    pub fn suspendPane(self: *SesState, uuid: [32]u8) !void {
        const pane = self.panes.getPtr(uuid) orelse return error.PaneNotFound;

        // Remove from client's list
        if (pane.attached_to) |client_id| {
            if (self.getClient(client_id)) |client| {
                var i: usize = 0;
                while (i < client.pane_uuids.items.len) {
                    if (std.mem.eql(u8, &client.pane_uuids.items[i], &uuid)) {
                        _ = client.pane_uuids.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Check if sticky info is set - becomes sticky, otherwise orphaned
        if (pane.sticky_pwd != null and pane.sticky_key != null) {
            pane.state = .sticky;
            ses.debugLog("suspendPane: {s} -> sticky (pwd={s}, key={c})", .{ uuid[0..8], pane.sticky_pwd.?, pane.sticky_key.? });
        } else {
            pane.state = .orphaned;
            ses.debugLog("suspendPane: {s} -> orphaned (pwd={any}, key={any})", .{ uuid[0..8], pane.sticky_pwd != null, pane.sticky_key != null });
        }
        pane.attached_to = null;
        pane.orphaned_at = std.time.timestamp();
        self.dirty = true;
    }

    /// Kill a pane
    pub fn killPane(self: *SesState, uuid: [32]u8) !void {
        var pane = self.panes.fetchRemove(uuid) orelse return error.PaneNotFound;
        self.dirty = true;

        // Remove from client's pane_uuids list if attached
        if (pane.value.attached_to) |client_id| {
            if (self.getClient(client_id)) |client| {
                var i: usize = 0;
                while (i < client.pane_uuids.items.len) {
                    if (std.mem.eql(u8, &client.pane_uuids.items[i], &uuid)) {
                        _ = client.pane_uuids.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Stop pod process (which owns PTY)
        _ = std.c.kill(pane.value.pod_pid, std.c.SIG.TERM);

        // Clean up
        pane.value.deinit();
    }

    /// Get all orphaned panes
    pub fn getOrphanedPanes(self: *SesState, allocator: std.mem.Allocator) ![]Pane {
        var result: std.ArrayList(Pane) = .empty;
        errdefer result.deinit(allocator);

        var iter = self.panes.valueIterator();
        while (iter.next()) |pane| {
            if (pane.state == .orphaned or pane.state == .sticky) {
                try result.append(allocator, pane.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Clean up timed-out orphaned panes
    pub fn cleanupOrphanedPanes(self: *SesState) void {
        const now = std.time.timestamp();
        const timeout_secs = @as(i64, @intCast(self.orphan_timeout_hours)) * 3600;

        var to_remove: std.ArrayList([32]u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state == .orphaned or pane.state == .sticky) {
                if (pane.orphaned_at) |orphaned_time| {
                    if (now - orphaned_time > timeout_secs) {
                        to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                    }
                }
            }
        }

        for (to_remove.items) |uuid| {
            self.killPane(uuid) catch |e| {
                core.logging.logError("ses", "killPane failed in cleanupTimedOut", e);
            };
        }
    }

    /// Check if a pane's pod process is still alive.
    pub fn checkPaneAlive(self: *SesState, uuid: [32]u8) bool {
        const pane = self.panes.get(uuid) orelse return false;
        // kill(pid, 0) checks existence/permission without sending a signal.
        return std.c.kill(pane.pod_pid, 0) == 0;
    }

    /// Get pane by UUID
    pub fn getPane(self: *SesState, uuid: [32]u8) ?*Pane {
        return self.panes.getPtr(uuid);
    }
};
