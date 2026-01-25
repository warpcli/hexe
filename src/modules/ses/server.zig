const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;
const state = @import("state.zig");
const ses = @import("main.zig");

/// Maximum number of concurrent client connections (MUX instances).
const MAX_CLIENTS: usize = 64;

/// Server that handles mux connections
/// Note: Uses page_allocator internally to avoid GPA issues after fork/daemonization
pub const Server = struct {
    allocator: std.mem.Allocator,
    socket: ipc.Server,
    ses_state: *state.SesState,
    running: bool,
    // Track pending pop requests: mux_fd -> cli_fd
    pending_pop_requests: std.AutoHashMap(posix.fd_t, posix.fd_t),
    // Track which fds use binary control protocol (MUX_CTL and POD_CTL connections).
    binary_ctl_fds: std.AutoHashMap(posix.fd_t, void),
    // CLI fd waiting for exit_intent response.
    pending_exit_intent_cli_fd: ?posix.fd_t = null,
    // CLI fds waiting for float result, keyed by float pane UUID.
    pending_float_cli_fds: std.AutoHashMap([32]u8, posix.fd_t),

    pub fn init(_: std.mem.Allocator, ses_state: *state.SesState) !Server {
        // Use page_allocator for everything to avoid GPA issues after fork
        const page_alloc = std.heap.page_allocator;
        const socket_path = try ipc.getSesSocketPath(page_alloc);
        defer page_alloc.free(socket_path);

        const socket = try ipc.Server.init(page_alloc, socket_path);

        return Server{
            .allocator = page_alloc,
            .socket = socket,
            .ses_state = ses_state,
            .running = true,
            .pending_pop_requests = std.AutoHashMap(posix.fd_t, posix.fd_t).init(page_alloc),
            .binary_ctl_fds = std.AutoHashMap(posix.fd_t, void).init(page_alloc),
            .pending_float_cli_fds = std.AutoHashMap([32]u8, posix.fd_t).init(page_alloc),
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.pending_exit_intent_cli_fd) |fd| posix.close(fd);
        var float_it = self.pending_float_cli_fds.iterator();
        while (float_it.next()) |entry| posix.close(entry.value_ptr.*);
        self.pending_float_cli_fds.deinit();
        self.pending_pop_requests.deinit();
        self.binary_ctl_fds.deinit();
        self.socket.deinit();
    }

    /// Main server loop - handles connections and messages
    pub fn run(self: *Server) !void {
        // Use page_allocator for poll_fds to avoid GPA issues after fork
        const page_alloc = std.heap.page_allocator;
        var poll_fds: std.ArrayList(posix.pollfd) = .empty;
        defer poll_fds.deinit(page_alloc);

        // Add server socket
        try poll_fds.append(page_alloc, .{
            .fd = self.socket.getFd(),
            .events = posix.POLL.IN,
            .revents = 0,
        });

        var last_save: i64 = std.time.milliTimestamp();

        while (self.running) {
            // Periodic persistence (best-effort)
            const now_ms = std.time.milliTimestamp();
            if (self.ses_state.dirty and now_ms - last_save >= 1000) {
                @import("persist.zig").save(self.allocator, self.ses_state) catch |e| {
                    core.logging.logError("ses", "persist.save failed", e);
                };
                self.ses_state.dirty = false;
                last_save = now_ms;
            }
            // Add any newly created pod_vt fds to the poll set.
            for (self.ses_state.pending_poll_fds.items) |new_fd| {
                poll_fds.append(page_alloc, .{
                    .fd = new_fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }) catch {};
            }
            self.ses_state.pending_poll_fds.clearRetainingCapacity();

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
                    self.dispatchNewConnection(conn, page_alloc, &poll_fds);
                }
            }

            // Check client sockets
            var i: usize = 1;
            while (i < poll_fds.items.len) {
                const pfd = &poll_fds.items[i];

                if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
                    // Check if this is a VT routing fd (pod_vt or mux_vt).
                    const is_pod_vt = self.ses_state.pod_vt_to_pane_id.contains(pfd.fd);
                    const is_mux_vt = self.isMuxVtFd(pfd.fd);

                    if (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                        if (is_pod_vt) {
                            self.removePodVtFd(pfd.fd);
                        } else if (is_mux_vt) {
                            self.removeMuxVtFd(pfd.fd);
                        } else {
                            _ = self.binary_ctl_fds.remove(pfd.fd);
                            var client_id: ?usize = null;
                            for (self.ses_state.clients.items) |client| {
                                if (client.fd == pfd.fd or client.mux_ctl_fd == pfd.fd) {
                                    client_id = client.id;
                                    break;
                                }
                            }
                            if (client_id) |cid| self.ses_state.removeClient(cid);
                        }
                        posix.close(pfd.fd);
                        _ = poll_fds.orderedRemove(i);
                        continue;
                    }

                    if (pfd.revents & posix.POLL.IN != 0) {
                        if (is_pod_vt) {
                            // POD → MUX VT routing.
                            if (!self.routePodToMux(pfd.fd)) {
                                self.removePodVtFd(pfd.fd);
                                posix.close(pfd.fd);
                                _ = poll_fds.orderedRemove(i);
                                continue;
                            }
                        } else if (is_mux_vt) {
                            // MUX → POD VT routing.
                            if (!self.routeMuxToPod(pfd.fd)) {
                                self.removeMuxVtFd(pfd.fd);
                                posix.close(pfd.fd);
                                _ = poll_fds.orderedRemove(i);
                                continue;
                            }
                        } else if (self.binary_ctl_fds.contains(pfd.fd)) {
                            // Binary control message (MUX CTL or POD CTL).
                            if (!self.handleBinaryCtlMessage(pfd.fd)) {
                                _ = self.binary_ctl_fds.remove(pfd.fd);
                                var client_id2: ?usize = null;
                                for (self.ses_state.clients.items) |client| {
                                    if (client.fd == pfd.fd or client.mux_ctl_fd == pfd.fd) {
                                        client_id2 = client.id;
                                        break;
                                    }
                                }
                                if (client_id2) |cid| self.ses_state.removeClient(cid);
                                posix.close(pfd.fd);
                                _ = poll_fds.orderedRemove(i);
                                continue;
                            }
                        } else {
                            // Unknown fd — close and remove.
                            posix.close(pfd.fd);
                            _ = poll_fds.orderedRemove(i);
                            continue;
                        }
                    }
                }

                i += 1;
            }
        }
    }

    /// Dispatch a newly accepted connection based on its first (handshake) byte.
    fn dispatchNewConnection(self: *Server, conn: ipc.Connection, alloc: std.mem.Allocator, poll_fds: *std.ArrayList(posix.pollfd)) void {
        // Reject if at max capacity to prevent resource exhaustion.
        if (self.ses_state.clients.items.len >= MAX_CLIENTS) {
            ses.debugLog("max clients reached ({d}), rejecting connection", .{MAX_CLIENTS});
            var tmp = conn;
            tmp.close();
            return;
        }

        // The accepted fd is blocking. The client sends the handshake byte immediately
        // after connecting, so it should be available. Read it directly.
        var peek: [1]u8 = undefined;
        const n = posix.read(conn.fd, &peek) catch {
            var tmp = conn;
            tmp.close();
            return;
        };
        if (n == 0) {
            var tmp = conn;
            tmp.close();
            return;
        }

        switch (peek[0]) {
            wire.SES_HANDSHAKE_MUX_CTL => {
                // MUX binary control channel.
                ses.debugLog("accept: MUX ctl channel fd={d}", .{conn.fd});
                self.binary_ctl_fds.put(conn.fd, {}) catch {};
                poll_fds.append(alloc, .{
                    .fd = conn.fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }) catch {
                    _ = self.binary_ctl_fds.remove(conn.fd);
                    var tmp = conn;
                    tmp.close();
                };
            },
            wire.SES_HANDSHAKE_MUX_VT => {
                // MUX VT data channel — read 32-byte session_id to identify client.
                ses.debugLog("accept: MUX VT channel fd={d}", .{conn.fd});
                var sid: [32]u8 = undefined;
                wire.readExact(conn.fd, &sid) catch {
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Convert 32-char hex to 16-byte session_id for lookup.
                const session_id = core.uuid.hexToBin(sid) orelse {
                    // Invalid hex — close connection.
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Find client with matching session_id.
                var found = false;
                for (self.ses_state.clients.items) |*client| {
                    if (client.session_id) |csid| {
                        if (std.mem.eql(u8, &csid, &session_id)) {
                            if (client.mux_vt_fd) |old| posix.close(old);
                            client.mux_vt_fd = conn.fd;
                            ses.debugLog("MUX VT: assigned fd={d} to client_id={d}", .{ conn.fd, client.id });
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    ses.debugLog("MUX VT: no client for session {s}", .{sid});
                    var tmp = conn;
                    tmp.close();
                    return;
                }
                poll_fds.append(alloc, .{
                    .fd = conn.fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }) catch {
                    var tmp = conn;
                    tmp.close();
                };
            },
            wire.SES_HANDSHAKE_CLI => {
                // CLI tool request (focus_move, exit_intent, float).
                self.handleCliRequest(conn.fd);
            },
            wire.SES_HANDSHAKE_POD_CTL => {
                // POD control uplink — read 16-byte binary UUID.
                ses.debugLog("accept: POD ctl uplink fd={d}", .{conn.fd});
                var uuid_bin: [16]u8 = undefined;
                wire.readExact(conn.fd, &uuid_bin) catch {
                    var tmp = conn;
                    tmp.close();
                    return;
                };
                // Convert 16 binary bytes → 32-char hex UUID key.
                const uuid_hex = core.uuid.binToHex(uuid_bin);
                // Store fd in the pane's pod_ctl_fd.
                if (self.ses_state.panes.getPtr(uuid_hex)) |pane| {
                    if (pane.pod_ctl_fd) |old_fd| {
                        _ = self.binary_ctl_fds.remove(old_fd);
                        posix.close(old_fd);
                    }
                    pane.pod_ctl_fd = conn.fd;
                    self.binary_ctl_fds.put(conn.fd, {}) catch {};
                    // Add to poll set for reading control messages.
                    poll_fds.append(alloc, .{
                        .fd = conn.fd,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    }) catch {};
                } else {
                    ses.debugLog("POD ctl: unknown UUID {s}", .{uuid_hex});
                    var tmp = conn;
                    tmp.close();
                }
            },
            else => {
                // Unknown handshake byte — close.
                var tmp = conn;
                tmp.close();
            },
        }
    }

    /// Check if fd is a MUX VT data channel.
    fn isMuxVtFd(self: *Server, fd: posix.fd_t) bool {
        for (self.ses_state.clients.items) |client| {
            if (client.mux_vt_fd) |vt_fd| {
                if (vt_fd == fd) return true;
            }
        }
        return false;
    }

    /// Route VT data from POD → MUX.
    /// Reads a 5-byte pod_protocol frame header + payload from pod_vt_fd,
    /// wraps it in a 7-byte MuxVtHeader, and writes to the MUX VT channel.
    /// Returns false if the connection should be removed.
    fn routePodToMux(self: *Server, pod_vt_fd: posix.fd_t) bool {
        // Read 5-byte pod_protocol header (type:u8 + len:u32 big-endian).
        var hdr: [5]u8 = undefined;
        wire.readExact(pod_vt_fd, &hdr) catch return false;

        const frame_type = hdr[0];
        const payload_len = std.mem.readInt(u32, hdr[1..5], .big);

        // Safety cap.
        if (payload_len > 4 * 1024 * 1024) return false;

        // Look up pane_id.
        const pane_id = self.ses_state.pod_vt_to_pane_id.get(pod_vt_fd) orelse return false;
        ses.debugLog("vt pod->mux: pane_id={d} type={d} len={d}", .{ pane_id, frame_type, payload_len });

        // Find the MUX VT fd for this pane.
        const mux_vt_fd = self.findMuxVtForPane(pane_id) orelse {
            // No MUX connected — skip payload.
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };

        // Write 7-byte MuxVtHeader to MUX.
        var mux_hdr: wire.MuxVtHeader = .{
            .pane_id = pane_id,
            .frame_type = frame_type,
            .len = payload_len,
        };
        wire.writeAll(mux_vt_fd, std.mem.asBytes(&mux_hdr)) catch {
            self.skipBytes(pod_vt_fd, payload_len);
            return true;
        };

        // Splice payload: read from pod, write to mux.
        self.spliceData(pod_vt_fd, mux_vt_fd, payload_len) catch return false;
        return true;
    }

    /// Route VT data from MUX → POD.
    /// Reads a 7-byte MuxVtHeader + payload from mux_vt_fd,
    /// wraps it in a 5-byte pod_protocol header, and writes to the POD VT channel.
    /// Returns false if the connection should be removed.
    fn routeMuxToPod(self: *Server, mux_vt_fd: posix.fd_t) bool {
        // Read 7-byte MuxVtHeader.
        const mux_hdr = wire.readMuxVtHeader(mux_vt_fd) catch return false;
        ses.debugLog("vt mux->pod: pane_id={d} type={d} len={d}", .{ mux_hdr.pane_id, mux_hdr.frame_type, mux_hdr.len });

        // Safety cap.
        if (mux_hdr.len > 4 * 1024 * 1024) return false;

        // Look up pod_vt_fd from pane_id.
        const pod_vt_fd = self.ses_state.pane_id_to_pod_vt.get(mux_hdr.pane_id) orelse {
            // Unknown pane — skip payload.
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            return true;
        };

        // Write 5-byte pod_protocol header to POD.
        var pod_hdr: [5]u8 = undefined;
        pod_hdr[0] = mux_hdr.frame_type;
        std.mem.writeInt(u32, pod_hdr[1..5], mux_hdr.len, .big);
        wire.writeAll(pod_vt_fd, &pod_hdr) catch {
            self.skipBytes(mux_vt_fd, mux_hdr.len);
            return true;
        };

        // Splice payload: read from mux, write to pod.
        self.spliceData(mux_vt_fd, pod_vt_fd, mux_hdr.len) catch return false;
        return true;
    }

    /// Find the MUX VT fd that should receive output for a given pane_id.
    fn findMuxVtForPane(self: *Server, pane_id: u16) ?posix.fd_t {
        // Find which pane has this pane_id, then find its owning client's mux_vt_fd.
        var pane_iter = self.ses_state.panes.valueIterator();
        while (pane_iter.next()) |pane| {
            if (pane.pane_id == pane_id) {
                if (pane.attached_to) |client_id| {
                    if (self.ses_state.getClient(client_id)) |client| {
                        return client.mux_vt_fd;
                    }
                }
                return null;
            }
        }
        return null;
    }

    fn removePodVtFd(self: *Server, fd: posix.fd_t) void {
        ses.debugLog("remove pod_vt fd={d}", .{fd});
        const pane_id = if (self.ses_state.pod_vt_to_pane_id.fetchRemove(fd)) |kv| blk: {
            _ = self.ses_state.pane_id_to_pod_vt.remove(kv.value);
            break :blk kv.value;
        } else null;

        // Clear from pane and notify MUX.
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.pod_vt_fd) |vt_fd| {
                if (vt_fd == fd) {
                    @constCast(pane).pod_vt_fd = null;
                    // Notify the owning MUX that this pane exited.
                    if (pane.attached_to) |client_id| {
                        if (self.ses_state.getClient(client_id)) |client| {
                            if (client.mux_ctl_fd) |ctl_fd| {
                                const uuid = entry.key_ptr.*;
                                ses.debugLog("pane_exited: uuid={s} pane_id={?d}", .{ uuid[0..8], pane_id });
                                var msg = wire.PaneUuid{ .uuid = uuid };
                                wire.writeControl(ctl_fd, .pane_exited, std.mem.asBytes(&msg)) catch {};
                            }
                        }
                    }
                    return;
                }
            }
        }
    }

    fn removeMuxVtFd(self: *Server, fd: posix.fd_t) void {
        ses.debugLog("remove mux_vt fd={d}", .{fd});
        for (self.ses_state.clients.items) |*client| {
            if (client.mux_vt_fd) |vt_fd| {
                if (vt_fd == fd) {
                    client.mux_vt_fd = null;
                    return;
                }
            }
        }
    }

    /// Read from src and write to dst, `len` bytes total.
    fn spliceData(_: *Server, src: posix.fd_t, dst: posix.fd_t, len: u32) !void {
        var remaining: usize = len;
        var buf: [16 * 1024]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(src, buf[0..chunk]) catch return error.ConnectionClosed;
            wire.writeAll(dst, buf[0..chunk]) catch return error.ConnectionClosed;
            remaining -= chunk;
        }
    }

    /// Discard `len` bytes from fd.
    fn skipBytes(_: *Server, fd: posix.fd_t, len: u32) void {
        var remaining: usize = len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
    }

    /// Find client_id for a binary CTL fd.
    fn findClientForCtlFd(self: *Server, fd: posix.fd_t) ?usize {
        for (self.ses_state.clients.items) |client| {
            if (client.fd == fd or client.mux_ctl_fd == fd) return client.id;
        }
        return null;
    }

    /// Handle a binary control message. Returns false if connection should be removed.
    fn handleBinaryCtlMessage(self: *Server, fd: posix.fd_t) bool {
        const hdr = wire.readControlHeader(fd) catch return false;
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        ses.debugLog("ctl msg: type=0x{x:0>4} len={d} fd={d}", .{ hdr.msg_type, hdr.payload_len, fd });
        var buf: [65536]u8 = undefined;

        switch (msg_type) {
            .ping => {
                wire.writeControl(fd, .pong, &.{}) catch {};
            },
            .register => {
                self.handleBinaryRegister(fd, hdr.payload_len, &buf);
            },
            .sync_state => {
                self.handleBinarySyncState(fd, hdr.payload_len, &buf);
            },
            .create_pane => {
                self.handleBinaryCreatePane(fd, hdr.payload_len, &buf);
            },
            .find_sticky => {
                self.handleBinaryFindSticky(fd, hdr.payload_len, &buf);
            },
            .orphan_pane => {
                self.handleBinaryOrphanPane(fd, hdr.payload_len, &buf);
            },
            .adopt_pane => {
                self.handleBinaryAdoptPane(fd, hdr.payload_len, &buf);
            },
            .kill_pane => {
                self.handleBinaryKillPane(fd, hdr.payload_len, &buf);
            },
            .set_sticky => {
                self.handleBinarySetSticky(fd, hdr.payload_len, &buf);
            },
            .get_pane_cwd => {
                self.handleBinaryGetPaneCwd(fd, hdr.payload_len, &buf);
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneUuid)) {
                    self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                    wire.writeControl(fd, .@"error", &.{}) catch {};
                    return false;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch return false;
                self.handleBinaryPaneInfo(fd, pu.uuid);
            },
            .list_orphaned => {
                self.handleBinaryListOrphaned(fd, &buf);
            },
            .list_sessions => {
                self.handleBinaryListSessions(fd, &buf);
            },
            .detach => {
                self.handleBinaryDetach(fd, hdr.payload_len, &buf);
            },
            .reattach => {
                self.handleBinaryReattach(fd, hdr.payload_len, &buf);
            },
            .disconnect => {
                self.handleBinaryDisconnect(fd, hdr.payload_len, &buf);
            },
            .update_pane_name => {
                self.handleBinaryUpdatePaneName(fd, hdr.payload_len, &buf);
            },
            .update_pane_shell => {
                self.handleBinaryUpdatePaneShell(fd, hdr.payload_len, &buf);
            },
            .update_pane_aux => {
                self.handleBinaryUpdatePaneAux(fd, hdr.payload_len, &buf);
            },
            .pop_response => {
                self.handleBinaryPopResponse(fd, hdr.payload_len, &buf);
            },
            .exit_intent_result => {
                self.handleBinaryExitIntentResult(fd, hdr.payload_len, &buf);
            },
            .float_result => {
                self.handleBinaryFloatResult(fd, hdr.payload_len, &buf);
            },
            // POD control channel messages
            .cwd_changed => {
                self.handleBinaryCwdChanged(fd, hdr.payload_len, &buf);
            },
            .fg_changed => {
                self.handleBinaryFgChanged(fd, hdr.payload_len, &buf);
            },
            .shell_event => {
                self.handleBinaryShellEvent(fd, hdr.payload_len, &buf);
            },
            .exited => {
                self.handleBinaryExited(fd, hdr.payload_len, &buf);
            },
            else => {
                // Unknown — skip payload and send error so the MUX doesn't hang.
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                wire.writeControl(fd, .@"error", &.{}) catch {};
            },
        }
        return true;
    }

    fn skipBinaryPayload(_: *Server, fd: posix.fd_t, len: u32, buf: []u8) void {
        var remaining: usize = len;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            wire.readExact(fd, buf[0..chunk]) catch return;
            remaining -= chunk;
        }
    }

    fn sendBinaryError(_: *Server, fd: posix.fd_t, msg: []const u8) void {
        var err_payload: wire.Error = .{ .msg_len = @intCast(@min(msg.len, std.math.maxInt(u16))) };
        wire.writeControlWithTrail(fd, .@"error", std.mem.asBytes(&err_payload), msg[0..err_payload.msg_len]) catch {};
    }

    fn handleBinaryRegister(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Register)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "register: payload too small");
            return;
        }
        const reg = wire.readStruct(wire.Register, fd) catch {
            self.sendBinaryError(fd, "register: read failed");
            return;
        };

        // Read trailing name.
        var name_slice: []const u8 = "";
        if (reg.name_len > 0 and reg.name_len <= buf.len) {
            wire.readExact(fd, buf[0..reg.name_len]) catch {
                self.sendBinaryError(fd, "register: name read failed");
                return;
            };
            name_slice = buf[0..reg.name_len];
        }

        // Convert 32-byte hex session_id to 16-byte binary.
        const session_id = core.uuid.hexToBin(reg.session_id) orelse {
            self.sendBinaryError(fd, "register: invalid session_id hex");
            return;
        };

        // Find or create client.
        const client_id = self.findClientForCtlFd(fd) orelse blk: {
            const cid = self.ses_state.addClient(fd) catch {
                self.sendBinaryError(fd, "register: addClient failed");
                return;
            };
            break :blk cid;
        };

        if (self.ses_state.getClient(client_id)) |client| {
            client.keepalive = (reg.keepalive != 0);
            client.session_id = session_id;
            client.mux_ctl_fd = fd;
            if (client.session_name) |old| client.allocator.free(old);
            client.session_name = if (name_slice.len > 0) client.allocator.dupe(u8, name_slice) catch null else null;
        }
        ses.debugLog("registered: session={s} name={s} client_id={d}", .{ reg.session_id[0..8], name_slice, client_id });

        wire.writeControl(fd, .registered, std.mem.asBytes(&wire.Registered{})) catch {};
    }

    fn handleBinarySyncState(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SyncState)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ss = wire.readStruct(wire.SyncState, fd) catch return;
        if (ss.state_len > 4 * 1024 * 1024) {
            self.skipBinaryPayload(fd, payload_len - @sizeOf(wire.SyncState), buf);
            return;
        }

        // Read state data into allocated buffer.
        const state_buf = self.allocator.alloc(u8, ss.state_len) catch {
            self.skipBinaryPayload(fd, ss.state_len, buf);
            return;
        };
        defer self.allocator.free(state_buf);
        wire.readExact(fd, state_buf) catch return;

        const client_id = self.findClientForCtlFd(fd) orelse return;
        if (self.ses_state.getClient(client_id)) |client| {
            client.updateMuxState(state_buf) catch {};
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryCreatePane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.CreatePane)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid_payload");
            return;
        }
        const cp = wire.readStruct(wire.CreatePane, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.CreatePane);

        // Read trailing: shell + cwd + sticky_pwd.
        if (trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            self.sendBinaryError(fd, "payload_too_large");
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch return;
        }

        ses.debugLog("create_pane: shell_len={d} cwd_len={d} sticky_key={d}", .{ cp.shell_len, cp.cwd_len, cp.sticky_key });

        var offset: usize = 0;
        const shell = if (cp.shell_len > 0 and offset + cp.shell_len <= trail_len) blk: {
            const s = buf[offset .. offset + cp.shell_len];
            offset += cp.shell_len;
            break :blk s;
        } else blk: {
            break :blk @as([]const u8, std.posix.getenv("SHELL") orelse "/bin/sh");
        };
        const cwd: ?[]const u8 = if (cp.cwd_len > 0 and offset + cp.cwd_len <= trail_len) blk: {
            const c = buf[offset .. offset + cp.cwd_len];
            offset += cp.cwd_len;
            break :blk c;
        } else null;
        const sticky_pwd: ?[]const u8 = if (cp.sticky_pwd_len > 0 and offset + cp.sticky_pwd_len <= trail_len) blk: {
            const p = buf[offset .. offset + cp.sticky_pwd_len];
            offset += cp.sticky_pwd_len;
            break :blk p;
        } else null;
        const sticky_key: ?u8 = if (cp.sticky_key != 0) cp.sticky_key else null;

        const client_id = self.findClientForCtlFd(fd) orelse blk: {
            const cid = self.ses_state.addClient(fd) catch {
                self.sendBinaryError(fd, "client_add_failed");
                return;
            };
            break :blk cid;
        };

        const pane = self.ses_state.createPane(client_id, shell, cwd, sticky_pwd, sticky_key, null, null) catch {
            self.sendBinaryError(fd, "create_failed");
            return;
        };
        self.ses_state.markDirty();
        ses.debugLog("binary: pane created {s} (pid={d}, pane_id={d})", .{ pane.uuid[0..8], pane.child_pid, pane.pane_id });

        // Send PaneCreated response.
        var resp = wire.PaneCreated{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_len = @intCast(pane.pod_socket_path.len),
        };
        wire.writeControlWithTrail(fd, .pane_created, std.mem.asBytes(&resp), pane.pod_socket_path) catch {};
    }

    fn handleBinaryFindSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FindSticky)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        }
        const fs = wire.readStruct(wire.FindSticky, fd) catch return;
        if (fs.pwd_len > buf.len) {
            self.skipBinaryPayload(fd, fs.pwd_len, buf);
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        }
        if (fs.pwd_len > 0) {
            wire.readExact(fd, buf[0..fs.pwd_len]) catch return;
        }
        const pwd = buf[0..fs.pwd_len];

        const client_id = self.findClientForCtlFd(fd) orelse {
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        };

        if (self.ses_state.findStickyPane(pwd, fs.key)) |pane| {
            _ = self.ses_state.attachPane(pane.uuid, client_id) catch {
                wire.writeControl(fd, .pane_not_found, &.{}) catch {};
                return;
            };
            var resp = wire.PaneFound{
                .uuid = pane.uuid,
                .pid = pane.child_pid,
                .pane_id = pane.pane_id,
                .socket_len = @intCast(pane.pod_socket_path.len),
            };
            wire.writeControlWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path) catch {};
        } else {
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
        }
    }

    fn handleBinaryOrphanPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch return;
        self.ses_state.suspendPane(pu.uuid) catch {};
        self.ses_state.markDirty();
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryAdoptPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid_payload");
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch return;

        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "no_client");
            return;
        };

        const pane = self.ses_state.attachPane(pu.uuid, client_id) catch {
            self.sendBinaryError(fd, "adopt_failed");
            return;
        };
        self.ses_state.markDirty();

        var resp = wire.PaneFound{
            .uuid = pane.uuid,
            .pid = pane.child_pid,
            .pane_id = pane.pane_id,
            .socket_len = @intCast(pane.pod_socket_path.len),
        };
        wire.writeControlWithTrail(fd, .pane_found, std.mem.asBytes(&resp), pane.pod_socket_path) catch {};
    }

    fn handleBinaryKillPane(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PaneUuid)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const pu = wire.readStruct(wire.PaneUuid, fd) catch return;
        self.ses_state.killPane(pu.uuid) catch {};
        self.ses_state.markDirty();
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinarySetSticky(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.SetSticky)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ss = wire.readStruct(wire.SetSticky, fd) catch return;
        if (ss.pwd_len > buf.len) {
            self.skipBinaryPayload(fd, ss.pwd_len, buf);
            return;
        }
        if (ss.pwd_len > 0) {
            wire.readExact(fd, buf[0..ss.pwd_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(ss.uuid)) |pane| {
            if (pane.sticky_pwd) |old| self.allocator.free(old);
            pane.sticky_pwd = if (ss.pwd_len > 0) self.allocator.dupe(u8, buf[0..ss.pwd_len]) catch null else null;
            pane.sticky_key = if (ss.key != 0) ss.key else null;
            if (pane.sticky_pwd != null) pane.state = .sticky;
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryGetPaneCwd(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.GetPaneCwd)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const gpc = wire.readStruct(wire.GetPaneCwd, fd) catch return;

        if (self.ses_state.getPane(gpc.uuid)) |pane| {
            const cwd = pane.getProcCwd();
            if (cwd) |c| {
                var resp = wire.PaneCwd{ .cwd_len = @intCast(c.len) };
                wire.writeControlWithTrail(fd, .get_pane_cwd, std.mem.asBytes(&resp), c) catch {};
                return;
            }
        }
        // No CWD available.
        var resp = wire.PaneCwd{ .cwd_len = 0 };
        wire.writeControl(fd, .get_pane_cwd, std.mem.asBytes(&resp)) catch {};
    }

    fn handleBinaryListOrphaned(self: *Server, fd: posix.fd_t, buf: []u8) void {
        _ = buf;
        const orphaned = self.ses_state.getOrphanedPanes(self.allocator) catch {
            var resp = wire.OrphanedPanes{ .pane_count = 0 };
            wire.writeControl(fd, .orphaned_panes, std.mem.asBytes(&resp)) catch {};
            return;
        };
        defer self.allocator.free(orphaned);

        // Build response: OrphanedPanes header + pane_count * OrphanedPaneEntry.
        var resp_hdr = wire.OrphanedPanes{ .pane_count = @intCast(@min(orphaned.len, 32)) };
        const entry_count: usize = resp_hdr.pane_count;
        const total_len = @sizeOf(wire.OrphanedPanes) + entry_count * @sizeOf(wire.OrphanedPaneEntry);

        var hdr: wire.ControlHeader = .{
            .msg_type = @intFromEnum(wire.MsgType.orphaned_panes),
            .payload_len = @intCast(total_len),
        };
        wire.writeAll(fd, std.mem.asBytes(&hdr)) catch return;
        wire.writeAll(fd, std.mem.asBytes(&resp_hdr)) catch return;

        for (orphaned[0..entry_count]) |pane| {
            var entry = wire.OrphanedPaneEntry{
                .uuid = pane.uuid,
                .pid = pane.child_pid,
            };
            wire.writeAll(fd, std.mem.asBytes(&entry)) catch return;
        }
    }

    fn handleBinaryListSessions(self: *Server, fd: posix.fd_t, buf: []u8) void {
        _ = buf;
        const sessions = self.ses_state.listDetachedSessions(self.allocator) catch {
            var resp = wire.SessionsList{ .session_count = 0 };
            wire.writeControl(fd, .sessions_list, std.mem.asBytes(&resp)) catch {};
            return;
        };
        defer self.allocator.free(sessions);

        // Calculate total payload: SessionsList + entries + name strings.
        var total: usize = @sizeOf(wire.SessionsList);
        for (sessions) |s| {
            total += @sizeOf(wire.SessionEntry) + s.session_name.len;
        }

        var hdr: wire.ControlHeader = .{
            .msg_type = @intFromEnum(wire.MsgType.sessions_list),
            .payload_len = @intCast(total),
        };
        wire.writeAll(fd, std.mem.asBytes(&hdr)) catch return;

        var resp_hdr = wire.SessionsList{ .session_count = @intCast(sessions.len) };
        wire.writeAll(fd, std.mem.asBytes(&resp_hdr)) catch return;

        for (sessions) |s| {
            const hex_id: [32]u8 = std.fmt.bytesToHex(&s.session_id, .lower);
            var entry = wire.SessionEntry{
                .session_id = hex_id,
                .pane_count = @intCast(s.pane_count),
                .name_len = @intCast(s.session_name.len),
            };
            wire.writeAll(fd, std.mem.asBytes(&entry)) catch return;
            if (s.session_name.len > 0) {
                wire.writeAll(fd, s.session_name) catch return;
            }
        }
    }

    fn handleBinaryDetach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Detach)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid_payload");
            return;
        }
        const det = wire.readStruct(wire.Detach, fd) catch return;
        if (det.state_len > 4 * 1024 * 1024) {
            self.skipBinaryPayload(fd, det.state_len, buf);
            self.sendBinaryError(fd, "state_too_large");
            return;
        }

        // Read mux state.
        const state_data = self.allocator.alloc(u8, det.state_len) catch {
            self.skipBinaryPayload(fd, det.state_len, buf);
            self.sendBinaryError(fd, "alloc_failed");
            return;
        };
        defer self.allocator.free(state_data);
        wire.readExact(fd, state_data) catch return;

        // Convert session_id hex to binary.
        const session_id = core.uuid.hexToBin(det.session_id) orelse {
            self.sendBinaryError(fd, "invalid_session_id");
            return;
        };

        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "no_client");
            return;
        };

        const session_name = if (self.ses_state.getClient(client_id)) |client|
            client.session_name orelse "unknown"
        else
            "unknown";

        if (self.ses_state.detachSession(client_id, session_id, session_name, state_data)) {
            self.ses_state.markDirty();
            wire.writeControl(fd, .session_detached, &.{}) catch {};
        } else {
            self.sendBinaryError(fd, "detach_failed");
        }
    }

    fn handleBinaryReattach(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Reattach)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            self.sendBinaryError(fd, "invalid_payload");
            return;
        }
        const ra = wire.readStruct(wire.Reattach, fd) catch return;
        if (ra.id_len > buf.len or ra.id_len == 0) {
            self.skipBinaryPayload(fd, ra.id_len, buf);
            self.sendBinaryError(fd, "invalid_id");
            return;
        }
        wire.readExact(fd, buf[0..ra.id_len]) catch return;
        const id_prefix = buf[0..ra.id_len];

        // Find matching session.
        var matched_session_id: ?[16]u8 = null;
        var match_count: usize = 0;
        var ds_iter = self.ses_state.detached_sessions.iterator();
        while (ds_iter.next()) |entry| {
            const key_ptr = entry.key_ptr;
            const detached = entry.value_ptr;
            const hex_id: [32]u8 = std.fmt.bytesToHex(key_ptr, .lower);

            if (std.mem.startsWith(u8, &hex_id, id_prefix)) {
                matched_session_id = key_ptr.*;
                match_count += 1;
            } else if (std.ascii.eqlIgnoreCase(detached.session_name, id_prefix)) {
                matched_session_id = key_ptr.*;
                match_count += 1;
            } else if (id_prefix.len >= 3 and detached.session_name.len >= id_prefix.len) {
                var match = true;
                for (id_prefix, 0..) |c, i| {
                    if (std.ascii.toLower(c) != std.ascii.toLower(detached.session_name[i])) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    matched_session_id = key_ptr.*;
                    match_count += 1;
                }
            }
        }

        if (match_count == 0) {
            self.sendBinaryError(fd, "session_not_found");
            return;
        }
        if (match_count > 1) {
            self.sendBinaryError(fd, "ambiguous_session_id");
            return;
        }

        const session_id = matched_session_id.?;
        const client_id = self.findClientForCtlFd(fd) orelse {
            self.sendBinaryError(fd, "no_client");
            return;
        };

        const result = self.ses_state.reattachSession(session_id, client_id) catch {
            self.sendBinaryError(fd, "reattach_failed");
            return;
        };
        if (result == null) {
            self.sendBinaryError(fd, "session_not_found");
            return;
        }
        const reattach_result = result.?;
        defer {
            self.allocator.free(reattach_result.mux_state_json);
            self.allocator.free(reattach_result.pane_uuids);
        }
        self.ses_state.markDirty();

        // Send SessionReattached: header + mux_state bytes + pane_count * 32 UUID bytes.
        var resp = wire.SessionReattached{
            .state_len = @intCast(reattach_result.mux_state_json.len),
            .pane_count = @intCast(reattach_result.pane_uuids.len),
        };
        const uuid_data_len = reattach_result.pane_uuids.len * 32;
        const total_payload = @sizeOf(wire.SessionReattached) + reattach_result.mux_state_json.len + uuid_data_len;

        var ctrl_hdr: wire.ControlHeader = .{
            .msg_type = @intFromEnum(wire.MsgType.session_reattached),
            .payload_len = @intCast(total_payload),
        };
        wire.writeAll(fd, std.mem.asBytes(&ctrl_hdr)) catch return;
        wire.writeAll(fd, std.mem.asBytes(&resp)) catch return;
        wire.writeAll(fd, reattach_result.mux_state_json) catch return;
        for (reattach_result.pane_uuids) |uuid| {
            wire.writeAll(fd, &uuid) catch return;
        }
    }

    fn handleBinaryDisconnect(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Disconnect)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const dc = wire.readStruct(wire.Disconnect, fd) catch return;
        const client_id = self.findClientForCtlFd(fd) orelse return;

        if (dc.mode == 0) { // shutdown
            self.ses_state.shutdownClient(client_id, dc.preserve_sticky != 0);
        } else {
            self.ses_state.removeClientGraceful(client_id);
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryUpdatePaneName(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneName)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const upn = wire.readStruct(wire.UpdatePaneName, fd) catch return;
        if (upn.name_len > buf.len) {
            self.skipBinaryPayload(fd, upn.name_len, buf);
            return;
        }
        if (upn.name_len > 0) {
            wire.readExact(fd, buf[0..upn.name_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(upn.uuid)) |pane| {
            if (pane.name) |old| self.allocator.free(old);
            pane.name = if (upn.name_len > 0) self.allocator.dupe(u8, buf[0..upn.name_len]) catch null else null;
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryUpdatePaneAux(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneAux)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const upa = wire.readStruct(wire.UpdatePaneAux, fd) catch return;

        if (self.ses_state.panes.getPtr(upa.uuid)) |pane| {
            if (upa.has_created_from != 0) {
                pane.created_from = upa.created_from;
            }
            if (upa.has_focused_from != 0) {
                pane.focused_from = upa.focused_from;
            }
            pane.is_focused = (upa.is_focused != 0);
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryUpdatePaneShell(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.UpdatePaneShell)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ups = wire.readStruct(wire.UpdatePaneShell, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.UpdatePaneShell);
        if (trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch return;
        }

        var offset: usize = 0;
        const cmd: ?[]const u8 = if (ups.cmd_len > 0 and offset + ups.cmd_len <= trail_len) blk: {
            const c = buf[offset .. offset + ups.cmd_len];
            offset += ups.cmd_len;
            break :blk c;
        } else null;
        const cwd: ?[]const u8 = if (ups.cwd_len > 0 and offset + ups.cwd_len <= trail_len) blk: {
            const c = buf[offset .. offset + ups.cwd_len];
            offset += ups.cwd_len;
            break :blk c;
        } else null;

        if (self.ses_state.panes.getPtr(ups.uuid)) |pane| {
            if (ups.has_status != 0) pane.last_status = ups.status;
            if (cmd) |c| {
                if (pane.last_cmd) |old| self.allocator.free(old);
                pane.last_cmd = self.allocator.dupe(u8, c) catch null;
            }
            if (cwd) |c| {
                if (pane.cwd) |old| self.allocator.free(old);
                pane.cwd = self.allocator.dupe(u8, c) catch null;
            }
            self.ses_state.markDirty();
        }
        wire.writeControl(fd, .ok, &.{}) catch {};
    }

    fn handleBinaryPopResponse(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.PopResponse)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const pr = wire.readStruct(wire.PopResponse, fd) catch return;

        // Find the CLI fd waiting for this response.
        const cli_fd = self.pending_pop_requests.fetchRemove(fd);
        if (cli_fd) |kv| {
            wire.writeControl(kv.value, .pop_response, std.mem.asBytes(&pr)) catch {};
            posix.close(kv.value);
        }
    }

    fn handleBinaryCwdChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.CwdChanged)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const cc = wire.readStruct(wire.CwdChanged, fd) catch return;
        if (cc.cwd_len > buf.len) {
            self.skipBinaryPayload(fd, cc.cwd_len, buf);
            return;
        }
        if (cc.cwd_len > 0) {
            wire.readExact(fd, buf[0..cc.cwd_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(cc.uuid)) |pane| {
            ses.debugLog("cwd_changed: uuid={s} cwd={s}", .{ cc.uuid[0..8], if (cc.cwd_len > 0) buf[0..cc.cwd_len] else "(empty)" });
            if (pane.cwd) |old| self.allocator.free(old);
            pane.cwd = if (cc.cwd_len > 0) self.allocator.dupe(u8, buf[0..cc.cwd_len]) catch null else null;
            self.ses_state.markDirty();
        }
    }

    fn handleBinaryFgChanged(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FgChanged)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const fc = wire.readStruct(wire.FgChanged, fd) catch return;
        if (fc.name_len > buf.len) {
            self.skipBinaryPayload(fd, fc.name_len, buf);
            return;
        }
        if (fc.name_len > 0) {
            wire.readExact(fd, buf[0..fc.name_len]) catch return;
        }

        if (self.ses_state.panes.getPtr(fc.uuid)) |pane| {
            ses.debugLog("fg_changed: uuid={s} pid={d} name={s}", .{ fc.uuid[0..8], fc.pid, if (fc.name_len > 0) buf[0..fc.name_len] else "(empty)" });
            pane.fg_pid = fc.pid;
            if (pane.fg_process) |old| self.allocator.free(old);
            pane.fg_process = if (fc.name_len > 0) self.allocator.dupe(u8, buf[0..fc.name_len]) catch null else null;
            self.ses_state.markDirty();
        }
    }

    fn handleBinaryShellEvent(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.ShpShellEvent)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ev = wire.readStruct(wire.ShpShellEvent, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.ShpShellEvent);
        if (trail_len > buf.len) {
            self.skipBinaryPayload(fd, trail_len, buf);
            return;
        }
        if (trail_len > 0) {
            wire.readExact(fd, buf[0..trail_len]) catch return;
        }

        // Identify pane by pod_ctl_fd.
        var pane_uuid: ?[32]u8 = null;
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            if (entry.value_ptr.pod_ctl_fd) |ctl_fd| {
                if (ctl_fd == fd) {
                    pane_uuid = entry.key_ptr.*;
                    break;
                }
            }
        }
        const uuid = pane_uuid orelse return;
        ses.debugLog("shell_event: uuid={s} phase={d} status={d}", .{ uuid[0..8], ev.phase, ev.status });

        // Forward to MUX as ForwardedShellEvent.
        var fwd = wire.ForwardedShellEvent{
            .uuid = uuid,
            .phase = ev.phase,
            .status = ev.status,
            .duration_ms = ev.duration_ms,
            .started_at = ev.started_at,
            .jobs = ev.jobs,
            .running = ev.running,
            .cmd_len = ev.cmd_len,
            .cwd_len = ev.cwd_len,
        };

        // Find the MUX CTL fd for this pane's owning client.
        if (self.ses_state.panes.get(uuid)) |pane| {
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    if (client.mux_ctl_fd) |mux_fd| {
                        const trails: []const []const u8 = &.{buf[0..trail_len]};
                        wire.writeControlMsg(mux_fd, .shell_event, std.mem.asBytes(&fwd), trails) catch {};
                    }
                }
            }
        }
    }

    fn handleBinaryExited(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.Exited)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const ex = wire.readStruct(wire.Exited, fd) catch return;

        if (self.ses_state.panes.getPtr(ex.uuid)) |pane| {
            pane.last_status = ex.status;
            self.ses_state.markDirty();
        }
    }

    /// Handle a CLI tool request (handshake byte 0x04).
    /// CLI sends one control message; SES forwards to MUX and optionally waits for response.
    fn handleCliRequest(self: *Server, fd: posix.fd_t) void {
        const hdr = wire.readControlHeader(fd) catch {
            posix.close(fd);
            return;
        };
        const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
        ses.debugLog("cli req: type=0x{x:0>4} len={d} fd={d}", .{ hdr.msg_type, hdr.payload_len, fd });
        var buf: [65536]u8 = undefined;

        switch (msg_type) {
            .focus_move => {
                if (hdr.payload_len < @sizeOf(wire.FocusMove)) {
                    posix.close(fd);
                    return;
                }
                const fm = wire.readStruct(wire.FocusMove, fd) catch {
                    posix.close(fd);
                    return;
                };
                // Find MUX ctl fd for this pane's session.
                const mux_fd = self.findMuxCtlForUuid(fm.uuid) orelse {
                    posix.close(fd);
                    return;
                };
                // Forward to MUX.
                wire.writeControl(mux_fd, .focus_move, std.mem.asBytes(&fm)) catch {};
                posix.close(fd);
            },
            .exit_intent => {
                if (hdr.payload_len < @sizeOf(wire.ExitIntent)) {
                    posix.close(fd);
                    return;
                }
                const ei = wire.readStruct(wire.ExitIntent, fd) catch {
                    posix.close(fd);
                    return;
                };
                // Find MUX ctl fd.
                const mux_fd = self.findMuxCtlForUuid(ei.uuid) orelse {
                    // No MUX — allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    wire.writeControl(fd, .exit_intent_result, std.mem.asBytes(&allow)) catch {};
                    posix.close(fd);
                    return;
                };
                // Close any previous pending exit_intent CLI fd.
                if (self.pending_exit_intent_cli_fd) |old_fd| posix.close(old_fd);
                self.pending_exit_intent_cli_fd = fd;
                // Forward to MUX.
                wire.writeControl(mux_fd, .exit_intent, std.mem.asBytes(&ei)) catch {
                    // If forward fails, allow exit.
                    const allow = wire.ExitIntentResult{ .allow = 1 };
                    wire.writeControl(fd, .exit_intent_result, std.mem.asBytes(&allow)) catch {};
                    posix.close(fd);
                    self.pending_exit_intent_cli_fd = null;
                };
            },
            .float_request => {
                if (hdr.payload_len < @sizeOf(wire.FloatRequest)) {
                    posix.close(fd);
                    return;
                }
                const payload_len = hdr.payload_len;
                const fr = wire.readStruct(wire.FloatRequest, fd) catch {
                    posix.close(fd);
                    return;
                };
                // Read trailing data.
                const trail_len = payload_len - @sizeOf(wire.FloatRequest);
                if (trail_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                if (trail_len > 0) {
                    wire.readExact(fd, buf[0..trail_len]) catch {
                        posix.close(fd);
                        return;
                    };
                }
                // Find active MUX (use first connected client with mux_ctl_fd).
                const mux_fd = self.findAnyMuxCtl() orelse {
                    self.sendBinaryError(fd, "no_mux");
                    posix.close(fd);
                    return;
                };
                // Forward entire float_request to MUX.
                wire.writeControlWithTrail(mux_fd, .float_request, std.mem.asBytes(&fr), buf[0..trail_len]) catch {
                    self.sendBinaryError(fd, "forward_failed");
                    posix.close(fd);
                    return;
                };
                // Store CLI fd — MUX will respond with float_created or float_result.
                // We'll use a placeholder UUID (zeroed) until float_created gives us the real one.
                // For now, keep the fd in a temporary spot. When MUX sends float_created,
                // we move it to pending_float_cli_fds keyed by UUID.
                // Use a simple approach: store as pending with zeroed UUID.
                const zero_uuid: [32]u8 = .{0} ** 32;
                self.pending_float_cli_fds.put(zero_uuid, fd) catch {
                    self.sendBinaryError(fd, "track_failed");
                    posix.close(fd);
                };
            },
            .notify => {
                // Forward notify to MUX.
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                        posix.close(fd);
                        return;
                    };
                }
                const mux_fd = self.findAnyMuxCtl() orelse {
                    posix.close(fd);
                    return;
                };
                wire.writeControl(mux_fd, .notify, buf[0..hdr.payload_len]) catch {};
                posix.close(fd);
            },
            .send_keys => {
                if (hdr.payload_len < @sizeOf(wire.SendKeys)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const sk = wire.bytesToStruct(wire.SendKeys, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &sk.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(sk.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .send_keys, buf[0..hdr.payload_len]) catch {};
                }
                posix.close(fd);
            },
            .targeted_notify => {
                if (hdr.payload_len < @sizeOf(wire.TargetedNotify)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const tn = wire.bytesToStruct(wire.TargetedNotify, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const mux_fd = self.findMuxCtlForUuid(tn.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .targeted_notify, buf[0..hdr.payload_len]) catch {};
                }
                posix.close(fd);
            },
            .broadcast_notify => {
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > 0) {
                    wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                        posix.close(fd);
                        return;
                    };
                }
                // Forward to all connected MUX clients.
                for (self.ses_state.clients.items) |*client| {
                    if (client.mux_ctl_fd) |mfd| {
                        wire.writeControl(mfd, .notify, buf[0..hdr.payload_len]) catch {};
                    }
                }
                posix.close(fd);
            },
            .pop_confirm => {
                if (hdr.payload_len < @sizeOf(wire.PopConfirm)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const pc = wire.bytesToStruct(wire.PopConfirm, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &pc.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(pc.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .pop_confirm, buf[0..hdr.payload_len]) catch {};
                    self.pending_pop_requests.put(mfd, fd) catch {
                        posix.close(fd);
                    };
                } else {
                    posix.close(fd);
                }
            },
            .pop_choose => {
                if (hdr.payload_len < @sizeOf(wire.PopChoose)) {
                    posix.close(fd);
                    return;
                }
                if (hdr.payload_len > buf.len) {
                    posix.close(fd);
                    return;
                }
                wire.readExact(fd, buf[0..hdr.payload_len]) catch {
                    posix.close(fd);
                    return;
                };
                const pch = wire.bytesToStruct(wire.PopChoose, buf[0..hdr.payload_len]) orelse {
                    posix.close(fd);
                    return;
                };
                const zero_uuid: [32]u8 = .{0} ** 32;
                const mux_fd = if (std.mem.eql(u8, &pch.uuid, &zero_uuid))
                    self.findAnyMuxCtl()
                else
                    self.findMuxCtlForUuid(pch.uuid) orelse self.findAnyMuxCtl();
                if (mux_fd) |mfd| {
                    wire.writeControl(mfd, .pop_choose, buf[0..hdr.payload_len]) catch {};
                    self.pending_pop_requests.put(mfd, fd) catch {
                        posix.close(fd);
                    };
                } else {
                    posix.close(fd);
                }
            },
            .pane_info => {
                if (hdr.payload_len < @sizeOf(wire.PaneUuid)) {
                    posix.close(fd);
                    return;
                }
                const pu = wire.readStruct(wire.PaneUuid, fd) catch {
                    posix.close(fd);
                    return;
                };
                self.handleBinaryPaneInfo(fd, pu.uuid);
                posix.close(fd);
            },
            .status => {
                // Payload is 1 byte: full_mode flag (0 or 1).
                var full_mode: bool = false;
                if (hdr.payload_len >= 1) {
                    var flag: [1]u8 = undefined;
                    wire.readExact(fd, &flag) catch {
                        posix.close(fd);
                        return;
                    };
                    full_mode = (flag[0] != 0);
                    // Skip any remaining bytes.
                    if (hdr.payload_len > 1) {
                        self.skipBinaryPayload(fd, hdr.payload_len - 1, &buf);
                    }
                }
                self.handleBinaryStatus(fd, full_mode);
            },
            else => {
                self.skipBinaryPayload(fd, hdr.payload_len, &buf);
                posix.close(fd);
            },
        }
    }

    /// Handle exit_intent_result from MUX — forward to waiting CLI.
    fn handleBinaryExitIntentResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.ExitIntentResult)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const result = wire.readStruct(wire.ExitIntentResult, fd) catch return;
        if (self.pending_exit_intent_cli_fd) |cli_fd| {
            wire.writeControl(cli_fd, .exit_intent_result, std.mem.asBytes(&result)) catch {};
            posix.close(cli_fd);
            self.pending_exit_intent_cli_fd = null;
        }
    }

    /// Handle float_result from MUX — forward to waiting CLI.
    fn handleBinaryFloatResult(self: *Server, fd: posix.fd_t, payload_len: u32, buf: []u8) void {
        if (payload_len < @sizeOf(wire.FloatResult)) {
            self.skipBinaryPayload(fd, payload_len, buf);
            return;
        }
        const result = wire.readStruct(wire.FloatResult, fd) catch return;
        const trail_len = payload_len - @sizeOf(wire.FloatResult);

        // Find CLI fd by UUID.
        var cli_fd: ?posix.fd_t = null;
        if (self.pending_float_cli_fds.fetchRemove(result.uuid)) |entry| {
            cli_fd = entry.value;
        } else {
            // Try zero UUID (pending assignment).
            const zero_uuid: [32]u8 = .{0} ** 32;
            if (self.pending_float_cli_fds.fetchRemove(zero_uuid)) |entry| {
                cli_fd = entry.value;
            }
        }

        if (cli_fd) |cfd| {
            // Forward the full message to CLI.
            if (trail_len > 0 and trail_len <= buf.len) {
                wire.readExact(fd, buf[0..trail_len]) catch {
                    posix.close(cfd);
                    return;
                };
                wire.writeControlWithTrail(cfd, .float_result, std.mem.asBytes(&result), buf[0..trail_len]) catch {};
            } else {
                wire.writeControl(cfd, .float_result, std.mem.asBytes(&result)) catch {};
                if (trail_len > 0) self.skipBinaryPayload(fd, @intCast(trail_len), buf);
            }
            posix.close(cfd);
        } else {
            // No CLI waiting — skip trailing data.
            if (trail_len > 0) self.skipBinaryPayload(fd, @intCast(trail_len), buf);
        }
    }

    /// Handle binary pane_info query — respond with PaneInfoResp.
    /// Does NOT close the fd — caller is responsible for closing if needed.
    fn handleBinaryPaneInfo(self: *Server, fd: posix.fd_t, uuid: [32]u8) void {
        ses.debugLog("pane_info: uuid={s} fd={d}", .{ uuid[0..8], fd });
        const pane = self.ses_state.panes.get(uuid) orelse {
            ses.debugLog("pane_info: not found", .{});
            wire.writeControl(fd, .pane_not_found, &.{}) catch {};
            return;
        };

        var resp: wire.PaneInfoResp = .{
            .uuid = uuid,
            .pid = pane.child_pid,
            .fg_pid = pane.fg_pid orelse pane.child_pid,
            .base_pid = pane.child_pid,
            .cols = pane.cols,
            .rows = pane.rows,
            .cursor_x = pane.cursor_x,
            .cursor_y = pane.cursor_y,
            .cursor_style = pane.cursor_style,
            .cursor_visible = @intFromBool(pane.cursor_visible),
            .alt_screen = @intFromBool(pane.alt_screen),
            .is_focused = @intFromBool(pane.is_focused),
            .pane_type = @intFromEnum(pane.pane_type),
            .state = @intFromEnum(pane.state),
            .last_status = if (pane.last_status) |s| s else 0,
            .has_last_status = @intFromBool(pane.last_status != null),
            .last_duration_ms = if (pane.last_duration_ms) |d| @intCast(d) else 0,
            .has_last_duration = @intFromBool(pane.last_duration_ms != null),
            .last_jobs = pane.last_jobs orelse 0,
            .has_last_jobs = @intFromBool(pane.last_jobs != null),
            .created_at = pane.created_at,
            .sticky_key = pane.sticky_key orelse 0,
            .has_sticky_key = @intFromBool(pane.sticky_key != null),
            .created_from = .{0} ** 32,
            .focused_from = .{0} ** 32,
            .has_created_from = 0,
            .has_focused_from = 0,
            .name_len = 0,
            .fg_len = 0,
            .cwd_len = 0,
            .tty_len = 0,
            .socket_path_len = 0,
            .session_name_len = 0,
            .layout_path_len = 0,
            .last_cmd_len = 0,
            .base_process_len = 0,
            .sticky_pwd_len = 0,
        };

        if (pane.created_from) |cf| {
            resp.created_from = cf;
            resp.has_created_from = 1;
        }
        if (pane.focused_from) |ff| {
            resp.focused_from = ff;
            resp.has_focused_from = 1;
        }

        // Gather trailing data in order: name, fg, cwd, tty, socket, session_name, layout, last_cmd, base_proc, sticky_pwd
        var trail_buf: [8192]u8 = undefined;
        var trail_len: usize = 0;

        // Name
        if (pane.name) |name| {
            const n = @min(name.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], name[0..n]);
            resp.name_len = @intCast(n);
            trail_len += n;
        }

        // Foreground process
        if (pane.getProcForegroundProcess()) |fg| {
            const n = @min(fg.name.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], fg.name[0..n]);
            resp.fg_len = @intCast(n);
            resp.fg_pid = fg.pid;
            trail_len += n;
        } else if (pane.fg_process) |proc| {
            const n = @min(proc.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], proc[0..n]);
            resp.fg_len = @intCast(n);
            trail_len += n;
        }

        // CWD
        const cwd = pane.getProcCwd() orelse pane.cwd;
        if (cwd) |c| {
            const n = @min(c.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], c[0..n]);
            resp.cwd_len = @intCast(n);
            trail_len += n;
        }

        // TTY
        if (pane.getProcTty()) |tty| {
            const n = @min(tty.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], tty[0..n]);
            resp.tty_len = @intCast(n);
            trail_len += n;
        }

        // Socket path
        {
            const sp = pane.pod_socket_path;
            const n = @min(sp.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], sp[0..n]);
            resp.socket_path_len = @intCast(n);
            trail_len += n;
        }

        // Session name (from attached client)
        if (pane.attached_to) |client_id| {
            if (self.ses_state.getClient(client_id)) |client| {
                if (client.session_name) |sn| {
                    const n = @min(sn.len, trail_buf.len - trail_len);
                    @memcpy(trail_buf[trail_len .. trail_len + n], sn[0..n]);
                    resp.session_name_len = @intCast(n);
                    trail_len += n;
                }
            }
        }

        // Layout path
        if (pane.layout_path) |path| {
            const n = @min(path.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], path[0..n]);
            resp.layout_path_len = @intCast(n);
            trail_len += n;
        }

        // Last command
        if (pane.last_cmd) |cmd| {
            const n = @min(cmd.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], cmd[0..n]);
            resp.last_cmd_len = @intCast(n);
            trail_len += n;
        }

        // Base process name
        if (pane.getProcProcessName()) |proc| {
            const n = @min(proc.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], proc[0..n]);
            resp.base_process_len = @intCast(n);
            trail_len += n;
        }

        // Sticky pwd
        if (pane.sticky_pwd) |pwd| {
            const n = @min(pwd.len, trail_buf.len - trail_len);
            @memcpy(trail_buf[trail_len .. trail_len + n], pwd[0..n]);
            resp.sticky_pwd_len = @intCast(n);
            trail_len += n;
        }

        wire.writeControlWithTrail(fd, .pane_info, std.mem.asBytes(&resp), trail_buf[0..trail_len]) catch {};
    }

    /// Handle binary status query from CLI — respond with StatusResp + entries.
    fn handleBinaryStatus(self: *Server, fd: posix.fd_t, full_mode: bool) void {
        ses.debugLog("status: full={} fd={d} clients={d} panes={d}", .{ full_mode, fd, self.ses_state.clients.items.len, self.ses_state.panes.count() });
        // Count entries
        var orphaned_count: u16 = 0;
        var sticky_count: u16 = 0;
        var pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |_entry| {
            const p = _entry.value_ptr;
            if (p.state == .orphaned) orphaned_count += 1;
            if (p.state == .sticky) sticky_count += 1;
        }

        const hdr = wire.StatusResp{
            .client_count = @intCast(self.ses_state.clients.items.len),
            .detached_count = @intCast(self.ses_state.detached_sessions.count()),
            .orphaned_count = orphaned_count,
            .sticky_count = sticky_count,
            .full_mode = @intFromBool(full_mode),
        };

        const alloc = self.ses_state.allocator;

        // Build the entire response in a dynamic buffer
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        // Header
        buf.appendSlice(alloc, std.mem.asBytes(&hdr)) catch {
            posix.close(fd);
            return;
        };

        // Connected clients
        for (self.ses_state.clients.items) |client| {
            var sc: wire.StatusClient = .{
                .id = @intCast(client.id),
                .session_id = .{0} ** 32,
                .has_session_id = 0,
                .name_len = 0,
                .pane_count = @intCast(client.pane_uuids.items.len),
                .mux_state_len = 0,
            };

            if (client.session_id) |sid| {
                const hex_id: [32]u8 = std.fmt.bytesToHex(sid, .lower);
                sc.session_id = hex_id;
                sc.has_session_id = 1;
            }

            const name = client.session_name orelse "";
            sc.name_len = @intCast(name.len);
            if (full_mode) {
                if (client.last_mux_state) |ms| {
                    sc.mux_state_len = @intCast(ms.len);
                }
            }

            buf.appendSlice(alloc, std.mem.asBytes(&sc)) catch {
                posix.close(fd);
                return;
            };
            if (name.len > 0) buf.appendSlice(alloc, name) catch {};
            if (full_mode) {
                if (client.last_mux_state) |ms| {
                    buf.appendSlice(alloc, ms) catch {};
                }
            }

            // Pane entries for this client
            for (client.pane_uuids.items) |uuid| {
                var pe: wire.StatusPaneEntry = .{
                    .uuid = uuid,
                    .pid = 0,
                    .name_len = 0,
                    .sticky_pwd_len = 0,
                };
                var pname: []const u8 = "";
                var spwd: []const u8 = "";
                if (self.ses_state.panes.get(uuid)) |pane| {
                    pe.pid = pane.child_pid;
                    if (pane.name) |n| {
                        pname = n;
                        pe.name_len = @intCast(n.len);
                    }
                    if (pane.sticky_pwd) |pwd| {
                        spwd = pwd;
                        pe.sticky_pwd_len = @intCast(pwd.len);
                    }
                }
                buf.appendSlice(alloc, std.mem.asBytes(&pe)) catch {};
                if (pname.len > 0) buf.appendSlice(alloc, pname) catch {};
                if (spwd.len > 0) buf.appendSlice(alloc, spwd) catch {};
            }
        }

        // Detached sessions
        var sess_iter = self.ses_state.detached_sessions.iterator();
        while (sess_iter.next()) |entry| {
            const detached = entry.value_ptr;
            const hex_id: [32]u8 = std.fmt.bytesToHex(detached.session_id, .lower);
            var de: wire.DetachedSessionEntry = .{
                .session_id = hex_id,
                .name_len = @intCast(detached.session_name.len),
                .pane_count = @intCast(detached.pane_uuids.len),
                .mux_state_len = 0,
            };
            if (full_mode) {
                de.mux_state_len = @intCast(detached.mux_state_json.len);
            }
            buf.appendSlice(alloc, std.mem.asBytes(&de)) catch {};
            buf.appendSlice(alloc, detached.session_name) catch {};
            if (full_mode) {
                buf.appendSlice(alloc, detached.mux_state_json) catch {};
            }
        }

        // Orphaned panes
        pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state != .orphaned) continue;
            var pe: wire.StatusPaneEntry = .{
                .uuid = entry.key_ptr.*,
                .pid = pane.child_pid,
                .name_len = 0,
                .sticky_pwd_len = 0,
            };
            if (pane.name) |n| pe.name_len = @intCast(n.len);
            buf.appendSlice(alloc, std.mem.asBytes(&pe)) catch {};
            if (pane.name) |n| buf.appendSlice(alloc, n) catch {};
        }

        // Sticky panes
        pane_iter = self.ses_state.panes.iterator();
        while (pane_iter.next()) |entry| {
            const pane = entry.value_ptr;
            if (pane.state != .sticky) continue;
            var se: wire.StickyPaneEntry = .{
                .uuid = entry.key_ptr.*,
                .pid = pane.child_pid,
                .key = pane.sticky_key orelse 0,
                .name_len = 0,
                .pwd_len = 0,
            };
            if (pane.name) |n| se.name_len = @intCast(n.len);
            if (pane.sticky_pwd) |pwd| se.pwd_len = @intCast(pwd.len);
            buf.appendSlice(alloc, std.mem.asBytes(&se)) catch {};
            if (pane.name) |n| buf.appendSlice(alloc, n) catch {};
            if (pane.sticky_pwd) |pwd| buf.appendSlice(alloc, pwd) catch {};
        }

        // Send all at once
        wire.writeControl(fd, .status, buf.items) catch {};
        posix.close(fd);
    }

    /// Find the MUX CTL fd for a given pane UUID.
    fn findMuxCtlForUuid(self: *Server, uuid: [32]u8) ?posix.fd_t {
        if (self.ses_state.panes.get(uuid)) |pane| {
            if (pane.attached_to) |client_id| {
                if (self.ses_state.getClient(client_id)) |client| {
                    return client.mux_ctl_fd;
                }
            }
        }
        // Fallback: try any connected MUX.
        return self.findAnyMuxCtl();
    }

    /// Find any connected MUX CTL fd.
    fn findAnyMuxCtl(self: *Server) ?posix.fd_t {
        for (self.ses_state.clients.items) |client| {
            if (client.mux_ctl_fd) |mux_fd| return mux_fd;
        }
        return null;
    }

    pub fn stop(self: *Server) void {
        self.running = false;
    }
};
