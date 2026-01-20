const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const state = @import("state.zig");

// Import handler modules
const pane_handlers = @import("handlers/pane.zig");
const session_handlers = @import("handlers/session.zig");
const notify_handlers = @import("handlers/notify.zig");
const pop_handlers = @import("handlers/pop.zig");

/// Message types from mux to ses
pub const RequestType = enum {
    create_pane,
    find_sticky,
    reconnect,
    disconnect,
    orphan_pane,
    list_orphaned,
    adopt_pane,
    kill_pane,
    ping,
    get_pane_cwd,
};

/// Message types from ses to mux
pub const ResponseType = enum {
    pane_created,
    pane_found,
    pane_not_found,
    reconnected,
    pane_exited,
    orphaned_panes,
    ok,
    @"error",
    pong,
};

/// Server that handles mux connections
pub const Server = struct {
    allocator: std.mem.Allocator,
    socket: ipc.Server,
    ses_state: *state.SesState,
    running: bool,
    // Track pending pop requests: mux_fd -> cli_fd
    pending_pop_requests: std.AutoHashMap(posix.fd_t, posix.fd_t),

    pub fn init(allocator: std.mem.Allocator, ses_state: *state.SesState) !Server {
        const socket_path = try ipc.getSesSocketPath(allocator);
        defer allocator.free(socket_path);

        const socket = try ipc.Server.init(allocator, socket_path);

        return Server{
            .allocator = allocator,
            .socket = socket,
            .ses_state = ses_state,
            .running = true,
            .pending_pop_requests = std.AutoHashMap(posix.fd_t, posix.fd_t).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.pending_pop_requests.deinit();
        self.socket.deinit();
    }

    /// Main server loop - handles connections and messages
    pub fn run(self: *Server) !void {
        var poll_fds: std.ArrayList(posix.pollfd) = .empty;
        defer poll_fds.deinit(self.allocator);

        // Add server socket
        try poll_fds.append(self.allocator, .{
            .fd = self.socket.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        });

        var last_save: i64 = std.time.milliTimestamp();

        while (self.running) {
            // Periodic persistence (best-effort)
            const now_ms = std.time.milliTimestamp();
            if (self.ses_state.dirty and now_ms - last_save >= 1000) {
                @import("persist.zig").save(self.allocator, self.ses_state) catch {};
                self.ses_state.dirty = false;
                last_save = now_ms;
            }
            // Reset revents
            for (poll_fds.items) |*pfd| {
                pfd.revents = 0;
            }

            // Poll with timeout for cleanup + persistence tasks
            const ready = posix.poll(poll_fds.items, 1000) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };

            if (ready == 0) {
                // Timeout - do periodic cleanup
                self.ses_state.cleanupOrphanedPanes();
                continue;
            }

            // Check server socket for new connections
            if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
                if (self.socket.tryAccept() catch null) |conn| {
                    try poll_fds.append(self.allocator, .{
                        .fd = conn.fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    });
                }
            }

            // Check client sockets
            var i: usize = 1;
            while (i < poll_fds.items.len) {
                const pfd = &poll_fds.items[i];

                if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    var conn = ipc.Connection{ .fd = pfd.fd };

                    // Find client ID for this fd
                    var client_id: ?usize = null;
                    for (self.ses_state.clients.items) |client| {
                        if (client.fd == pfd.fd) {
                            client_id = client.id;
                            break;
                        }
                    }

                    if (pfd.revents & posix.POLL.IN != 0) {
                        // Try to read message
                        var buf: [65536]u8 = undefined;
                        const line = conn.recvLine(&buf) catch null;

                        if (line) |msg| {
                            self.handleMessage(&conn, client_id, pfd.fd, msg) catch |err| {
                                self.sendError(&conn, @errorName(err)) catch {};
                            };
                        } else {
                            // Connection closed
                            if (client_id) |cid| {
                                self.ses_state.removeClient(cid);
                            }
                            conn.close();
                            _ = poll_fds.orderedRemove(i);
                            continue;
                        }
                    }

                    if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                        // Connection error or hangup
                        if (client_id) |cid| {
                            self.ses_state.removeClient(cid);
                        }
                        conn.close();
                        _ = poll_fds.orderedRemove(i);
                        continue;
                    }
                }

                i += 1;
            }
        }
    }

    /// Handle a message from a client
    fn handleMessage(self: *Server, conn: *ipc.Connection, client_id: ?usize, fd: posix.fd_t, msg: []const u8) !void {
        // Parse JSON message
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch {
            try self.sendError(conn, "invalid_json");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = root.get("type") orelse {
            try self.sendError(conn, "missing_type");
            return;
        };

        const type_str = msg_type.string;

        // Read-only queries - don't need a registered client
        if (std.mem.eql(u8, type_str, "ping")) {
            try conn.sendLine("{\"type\":\"pong\"}");
            return;
        } else if (std.mem.eql(u8, type_str, "status")) {
            try notify_handlers.handleStatus(self.allocator, self.ses_state, conn, root, sendErrorFn);
            return;
        } else if (std.mem.eql(u8, type_str, "list_orphaned")) {
            try pane_handlers.handleListOrphaned(self.allocator, self.ses_state, conn);
            return;
        } else if (std.mem.eql(u8, type_str, "disconnect")) {
            if (client_id) |cid| {
                const mode = if (root.get("mode")) |m| m.string else "graceful";
                const preserve_sticky = if (root.get("preserve_sticky")) |p| p.bool else true;

                if (std.mem.eql(u8, mode, "shutdown")) {
                    self.ses_state.shutdownClient(cid, preserve_sticky);
                } else {
                    self.ses_state.removeClientGraceful(cid);
                }
            }
            try conn.sendLine("{\"type\":\"ok\"}");
            return;
        }

        // Operations that need a client - register if not already registered
        const cid = client_id orelse blk: {
            const new_id = try self.ses_state.addClient(fd);
            break :blk new_id;
        };

        // Route to appropriate handler
        if (std.mem.eql(u8, type_str, "register")) {
            try session_handlers.handleRegister(self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "sync_state")) {
            try session_handlers.handleSyncState(self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "create_pane")) {
            try pane_handlers.handleCreatePane(self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "find_sticky")) {
            try pane_handlers.handleFindSticky(self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "reconnect")) {
            try pane_handlers.handleReconnect(self.allocator, self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "orphan_pane")) {
            try pane_handlers.handleOrphanPane(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "adopt_pane")) {
            try pane_handlers.handleAdoptPane(self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "kill_pane")) {
            try pane_handlers.handleKillPane(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "set_sticky")) {
            try pane_handlers.handleSetSticky(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "broadcast_notify")) {
            try notify_handlers.handleBroadcastNotify(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "targeted_notify") or std.mem.eql(u8, type_str, "pop_notify")) {
            try notify_handlers.handleTargetedNotify(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "pop_confirm")) {
            try pop_handlers.handlePopConfirm(self.ses_state, &self.pending_pop_requests, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "pop_choose")) {
            try pop_handlers.handlePopChoose(self.ses_state, &self.pending_pop_requests, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "pane_info")) {
            try pane_handlers.handlePaneInfo(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "get_pane_cwd")) {
            try pane_handlers.handleGetPaneCwd(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "detach_session")) {
            try session_handlers.handleDetachSession(self.allocator, self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "reattach")) {
            try session_handlers.handleReattach(self.allocator, self.ses_state, conn, cid, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "list_sessions")) {
            try session_handlers.handleListSessions(self.allocator, self.ses_state, conn, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "update_pane_aux")) {
            try pane_handlers.handleUpdatePaneAux(self.ses_state, conn, root, sendErrorFn);
        } else if (std.mem.eql(u8, type_str, "pop_response")) {
            try pop_handlers.handlePopResponse(&self.pending_pop_requests, conn, root);
        } else {
            try self.sendError(conn, "unknown_type");
        }
    }

    fn sendError(self: *Server, conn: *ipc.Connection, msg: []const u8) !void {
        _ = self;
        var buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"{s}\"}}\n", .{msg});
        try conn.send(response);
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};

/// Function pointer for sendError to pass to handlers
fn sendErrorFn(conn: *ipc.Connection, msg: []const u8) anyerror!void {
    var buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "{{\"type\":\"error\",\"message\":\"{s}\"}}\n", .{msg});
    try conn.send(response);
}
