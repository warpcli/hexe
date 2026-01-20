const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
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
    pod_pid: posix.pid_t,
    pod_socket_path: []const u8,
    child_pid: posix.pid_t,
    state: PaneState,

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
    // Current working directory (synced from mux, owned)
    cwd: ?[]const u8 = null,
    // Foreground process info (synced from mux)
    fg_process: ?[]const u8 = null,
    fg_pid: ?i32 = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Pane) void {
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
    }

    // Static buffer for getProcCwd to avoid returning dangling pointer
    var proc_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;

    /// Get current working directory from /proc/<child_pid>/cwd
    /// This is the authoritative CWD from OS, not dependent on shell OSC 7
    pub fn getProcCwd(self: *const Pane) ?[]const u8 {
        if (self.child_pid == 0) return null;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{self.child_pid}) catch return null;
        const link = posix.readlink(path, &proc_cwd_buf) catch return null;
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
        };
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
            client.deinit();
        }
        self.clients.deinit(self.allocator);
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
                            self.killPane(uuid) catch {};
                        }
                    }
                } else {
                    // No keepalive: kill all panes
                    for (client.pane_uuids.items) |uuid| {
                        self.killPane(uuid) catch {};
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
                    self.killPane(uuid) catch {};
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
    ) !*Pane {
        const uuid = ipc.generateUuid();
        const pod_socket_path = try ipc.getPodSocketPath(self.allocator, &uuid);

        const spawn = try self.spawnPod(uuid, pod_socket_path, shell, cwd);

        // Copy sticky_pwd if provided
        const owned_pwd: ?[]const u8 = if (sticky_pwd) |pwd|
            try self.allocator.dupe(u8, pwd)
        else
            null;

        const now = std.time.timestamp();

        const pane = Pane{
            .uuid = uuid,
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
            .allocator = self.allocator,
        };

        try self.panes.put(uuid, pane);
        self.dirty = true;

        // Add to client's pane list
        if (self.getClient(client_id)) |client| {
            try client.appendUuid(uuid);
        }

        return self.panes.getPtr(uuid).?;
    }

    fn spawnPod(
        self: *SesState,
        uuid: [32]u8,
        pod_socket_path: []const u8,
        shell: []const u8,
        cwd: ?[]const u8,
    ) !struct { pod_pid: posix.pid_t, child_pid: posix.pid_t } {
        var args_list: std.ArrayList([]const u8) = .empty;
        defer args_list.deinit(self.allocator);

        const exe_path = try std.fs.selfExePathAlloc(self.allocator);
        defer self.allocator.free(exe_path);

        try args_list.append(self.allocator, exe_path);
        try args_list.append(self.allocator, "pod");
        try args_list.append(self.allocator, "daemon");
        try args_list.append(self.allocator, "--uuid");
        try args_list.append(self.allocator, uuid[0..]);
        try args_list.append(self.allocator, "--socket");
        try args_list.append(self.allocator, pod_socket_path);
        try args_list.append(self.allocator, "--shell");
        try args_list.append(self.allocator, shell);
        if (cwd) |dir| {
            try args_list.append(self.allocator, "--cwd");
            try args_list.append(self.allocator, dir);
        }
        try args_list.append(self.allocator, "--foreground");

        var child = std.process.Child.init(args_list.items, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Pipe;

        try child.spawn();
        const pod_pid: posix.pid_t = @intCast(child.id);

        var stdout_file = child.stdout orelse return error.PodNoStdout;
        defer stdout_file.close();

        var line_buf: [512]u8 = undefined;
        var pos: usize = 0;
        while (pos < line_buf.len) {
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
            self.killPane(uuid) catch {};
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
