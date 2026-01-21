const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ghostty = @import("ghostty-vt");
const pod_protocol = core.pod_protocol;

const notification = @import("notification.zig");
const NotificationManager = notification.NotificationManager;
const pop = @import("pop");

const PodBackend = struct {
    conn: core.ipc.Connection,
    reader: pod_protocol.Reader,
    socket_path: []u8,

    pub fn deinit(self: *PodBackend, allocator: std.mem.Allocator) void {
        self.conn.close();
        self.reader.deinit(allocator);
        allocator.free(self.socket_path);
        self.* = undefined;
    }
};

const QueryState = enum {
    idle,
    esc,
    csi,
    dcs,
    dcs_esc,
};

const Backend = union(enum) {
    local: core.Pty,
    pod: PodBackend,
};

/// A Pane is a ghostty VT that receives bytes from either a local PTY
/// (legacy mode) or a per-pane pod process (persistent scrollback mode).
pub const Pane = struct {
    allocator: std.mem.Allocator = undefined,
    id: u16 = 0,
    vt: core.VT = .{},
    backend: Backend = undefined,

    // UUID for tracking (32 hex chars)
    uuid: [32]u8 = undefined,

    // Position and size in the terminal
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    // Is this pane focused?
    focused: bool = false,
    // Is this a floating pane?
    floating: bool = false,
    // Is this pane visible? (for floating panes that can be toggled)
    // For tab-bound floats, this is the simple visibility state
    visible: bool = true,
    // For global floats (parent_tab == null), per-tab visibility bitmask
    // Bit N = visible on tab N (supports up to 64 tabs)
    tab_visible: u64 = 0,
    // Key binding for this float (for matching)
    float_key: u8 = 0,
    // Outer border dimensions (for floating panes with padding)
    border_x: u16 = 0,
    border_y: u16 = 0,
    border_w: u16 = 0,
    border_h: u16 = 0,
    // Per-float style settings
    border_color: core.BorderColor = .{},
    // Float layout percentages (for resize recalculation)
    float_width_pct: u8 = 60,
    float_height_pct: u8 = 60,
    float_pos_x_pct: u8 = 50,
    float_pos_y_pct: u8 = 50,
    float_pad_x: u8 = 1,
    float_pad_y: u8 = 0,
    // For pwd floats: the directory this float is bound to
    pwd_dir: ?[]const u8 = null,
    is_pwd: bool = false,
    // Sticky float - survives mux exit, can be reattached
    sticky: bool = false,
    // Cached CWD from ses daemon (for pod panes where /proc access is in ses)
    ses_cwd: ?[]const u8 = null,
    // Exit status for local panes (set when process exits)
    exit_status: ?u32 = null,
    // Capture raw output for blocking floats
    capture_output: bool = false,
    captured_output: std.ArrayList(u8) = .empty,
    // For tab-bound floats: which tab owns this float
    // null = global float (special=true or pwd=true)
    parent_tab: ?usize = null,
    // Border style and optional module
    float_style: ?*const core.FloatStyle = null,

    // Tracks whether we saw a clear-screen sequence in the last output.
    did_clear: bool = false,
    // Keep last bytes so we can detect escape sequences across boundaries.
    esc_tail: [3]u8 = .{ 0, 0, 0 },
    esc_tail_len: u8 = 0,

    // Track terminal query sequences (DSR/DECRQSS).
    query_state: QueryState = .idle,
    query_buf: [64]u8 = undefined,
    query_len: u8 = 0,

    // OSC passthrough (clipboard, colors, etc.)
    osc_buf: std.ArrayList(u8) = .empty,
    osc_in_progress: bool = false,
    osc_pending_esc: bool = false,
    osc_prev_esc: bool = false,
    osc_expect_response: bool = false,

    // Pane-local notifications (PANE realm - renders at bottom of pane)
    notifications: NotificationManager = undefined,
    notifications_initialized: bool = false,
    // Pane-local popups (blocking at PANE level)
    popups: pop.PopupManager = undefined,
    popups_initialized: bool = false,

    /// Check if this float is visible on a specific tab
    pub fn isVisibleOnTab(self: *const Pane, tab: usize) bool {
        if (self.parent_tab != null) {
            return self.visible;
        }
        if (tab >= 64) return false;
        return (self.tab_visible & (@as(u64, 1) << @intCast(tab))) != 0;
    }

    pub fn takeOscExpectResponse(self: *Pane) bool {
        const v = self.osc_expect_response;
        self.osc_expect_response = false;
        return v;
    }

    /// Set visibility for this float on a specific tab
    pub fn setVisibleOnTab(self: *Pane, tab: usize, vis: bool) void {
        if (self.parent_tab != null) {
            self.visible = vis;
            return;
        }
        if (tab >= 64) return;
        const mask = @as(u64, 1) << @intCast(tab);
        if (vis) {
            self.tab_visible |= mask;
        } else {
            self.tab_visible &= ~mask;
        }
    }

    /// Toggle visibility for this float on a specific tab
    pub fn toggleVisibleOnTab(self: *Pane, tab: usize) void {
        self.setVisibleOnTab(tab, !self.isVisibleOnTab(tab));
    }

    pub fn init(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16) !void {
        return self.initWithCommand(allocator, id, x, y, width, height, null, null);
    }

    pub fn initWithCommand(
        self: *Pane,
        allocator: std.mem.Allocator,
        id: u16,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        command: ?[]const u8,
        cwd: ?[]const u8,
    ) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height };

        const cmd = command orelse (posix.getenv("SHELL") orelse "/bin/sh");
        var pty = try core.Pty.spawnWithCwd(cmd, cwd);
        errdefer pty.close();
        try pty.setSize(width, height);

        self.backend = .{ .local = pty };
        self.uuid = core.ipc.generateUuid();

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();

        self.notifications = NotificationManager.init(allocator);
        self.notifications_initialized = true;
        self.popups = pop.PopupManager.init(allocator);
        self.popups_initialized = true;
    }

    /// Initialize a pane backed by a per-pane pod process.
    /// `pod_socket_path` is duped and owned by the pane.
    pub fn initWithPod(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, pod_socket_path: []const u8, uuid: [32]u8) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height, .uuid = uuid };

        const owned_path = try allocator.dupe(u8, pod_socket_path);
        errdefer allocator.free(owned_path);

        var client = try core.ipc.Client.connect(owned_path);
        const conn = client.toConnection();

        var reader = try pod_protocol.Reader.init(allocator, pod_protocol.MAX_FRAME_LEN);
        errdefer reader.deinit(allocator);

        self.backend = .{ .pod = .{ .conn = conn, .socket_path = owned_path, .reader = reader } };

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();

        self.notifications = NotificationManager.init(allocator);
        self.notifications_initialized = true;
        self.popups = pop.PopupManager.init(allocator);
        self.popups_initialized = true;

        // Tell pod initial size.
        self.sendResizeToPod(width, height);
    }

    pub fn deinit(self: *Pane) void {
        switch (self.backend) {
            .local => |*pty| pty.close(),
            .pod => |*pod| pod.deinit(self.allocator),
        }
        self.vt.deinit();
        self.captured_output.deinit(self.allocator);
        if (self.pwd_dir) |dir| {
            self.allocator.free(dir);
        }
        if (self.ses_cwd) |cwd| {
            self.allocator.free(cwd);
        }
        if (self.notifications_initialized) {
            self.notifications.deinit();
        }
        if (self.popups_initialized) {
            self.popups.deinit();
        }
    }

    /// Set cached CWD from ses daemon (for pod panes)
    pub fn setSesCwd(self: *Pane, cwd: ?[]u8) void {
        // Free old cached CWD if any
        if (self.ses_cwd) |old| {
            self.allocator.free(old);
        }
        self.ses_cwd = cwd;
    }

    pub fn replaceWithPod(self: *Pane, pod_socket_path: []const u8, uuid: [32]u8) !void {
        // Close old backend.
        switch (self.backend) {
            .local => |*pty| pty.close(),
            .pod => |*pod| pod.deinit(self.allocator),
        }

        self.uuid = uuid;

        const owned_path = try self.allocator.dupe(u8, pod_socket_path);
        errdefer self.allocator.free(owned_path);

        var client = try core.ipc.Client.connect(owned_path);
        const conn = client.toConnection();
        var reader = try pod_protocol.Reader.init(self.allocator, pod_protocol.MAX_FRAME_LEN);
        errdefer reader.deinit(self.allocator);

        self.backend = .{ .pod = .{ .conn = conn, .socket_path = owned_path, .reader = reader } };

        // Reset VT state (will be reconstructed from pod backlog replay).
        self.vt.deinit();
        try self.vt.init(self.allocator, self.width, self.height);

        self.did_clear = false;
        self.esc_tail = .{ 0, 0, 0 };
        self.esc_tail_len = 0;
        self.osc_in_progress = false;
        self.osc_pending_esc = false;
        self.osc_prev_esc = false;
        self.osc_buf.clearRetainingCapacity();

        self.sendResizeToPod(self.width, self.height);
    }

    /// Respawn the shell process (local panes only).
    pub fn respawn(self: *Pane) !void {
        switch (self.backend) {
            .local => |*pty| {
                pty.close();
                const cmd = posix.getenv("SHELL") orelse "/bin/sh";
                var new_pty = try core.Pty.spawn(cmd);
                errdefer new_pty.close();
                try new_pty.setSize(self.width, self.height);
                self.backend = .{ .local = new_pty };

                self.osc_buf.deinit(self.allocator);
                self.vt.deinit();

                try self.vt.init(self.allocator, self.width, self.height);

                self.did_clear = false;
                self.esc_tail = .{ 0, 0, 0 };
                self.esc_tail_len = 0;
                self.osc_in_progress = false;
                self.osc_pending_esc = false;
                self.osc_prev_esc = false;
                self.osc_buf.clearRetainingCapacity();
            },
            .pod => return error.NotLocalPane,
        }
    }

    /// Read from backend and feed to VT. Returns true if data was read.
    pub fn poll(self: *Pane, buffer: []u8) !bool {
        self.did_clear = false;

        return switch (self.backend) {
            .local => |*pty| blk: {
                const n = pty.read(buffer) catch |err| {
                    if (err == error.WouldBlock) break :blk false;
                    return err;
                };
                if (n == 0) break :blk false;

                const data = buffer[0..n];
                self.processOutput(data);
                try self.vt.feed(data);
                break :blk true;
            },
            .pod => |*pod| blk: {
                const n = posix.read(pod.conn.fd, buffer) catch |err| {
                    if (err == error.WouldBlock) break :blk false;
                    return err;
                };
                if (n == 0) break :blk false;
                const data = buffer[0..n];
                pod.reader.feed(data, @ptrCast(self), podFrameCallback);
                break :blk true;
            },
        };
    }

    fn podFrameCallback(ctx: *anyopaque, frame: pod_protocol.Frame) void {
        const self: *Pane = @ptrCast(@alignCast(ctx));
        self.handlePodFrame(frame);
    }

    fn handlePodFrame(self: *Pane, frame: pod_protocol.Frame) void {
        switch (frame.frame_type) {
            .output => {
                self.processOutput(frame.payload);
                self.vt.feed(frame.payload) catch {};
            },
            .backlog_end => {},
            else => {},
        }
    }

    fn processOutput(self: *Pane, data: []const u8) void {
        if (self.capture_output) {
            self.appendCapturedOutput(data);
        }
        self.handleTerminalQueries(data);
        self.forwardOsc(data);

        if (containsClearSeq(self.esc_tail[0..self.esc_tail_len], data)) {
            self.did_clear = true;
        }

        const take: usize = @min(@as(usize, 3), data.len);
        if (take > 0) {
            @memcpy(self.esc_tail[0..take], data[data.len - take .. data.len]);
            self.esc_tail_len = @intCast(take);
        }
    }

    fn forwardOsc(self: *Pane, data: []const u8) void {
        const ESC: u8 = 0x1b;
        const BEL: u8 = 0x07;

        for (data) |b| {
            if (!self.osc_in_progress) {
                if (self.osc_pending_esc) {
                    self.osc_pending_esc = false;
                    if (b == ']') {
                        self.osc_in_progress = true;
                        self.osc_prev_esc = false;
                        self.osc_buf.clearRetainingCapacity();
                        self.osc_buf.append(self.allocator, ESC) catch {
                            self.osc_in_progress = false;
                            continue;
                        };
                        self.osc_buf.append(self.allocator, ']') catch {
                            self.osc_in_progress = false;
                            continue;
                        };
                        continue;
                    }
                }

                if (b == ESC) {
                    self.osc_pending_esc = true;
                }
                continue;
            }

            // In OSC.
            self.osc_buf.append(self.allocator, b) catch {
                self.osc_in_progress = false;
                self.osc_pending_esc = false;
                self.osc_prev_esc = false;
                self.osc_buf.clearRetainingCapacity();
                continue;
            };

            var done = false;
            if (b == BEL) {
                done = true;
            } else if (self.osc_prev_esc and b == '\\') {
                done = true;
            }
            self.osc_prev_esc = (b == ESC);

            if (self.osc_buf.items.len > 64 * 1024) {
                // Safety bound: drop runaway sequences.
                self.osc_in_progress = false;
                self.osc_pending_esc = false;
                self.osc_prev_esc = false;
                self.osc_buf.clearRetainingCapacity();
                continue;
            }

            if (done) {
                self.osc_in_progress = false;
                self.osc_pending_esc = false;
                self.osc_prev_esc = false;

                if (shouldPassthroughOsc(self.osc_buf.items)) {
                    const code = parseOscCode(self.osc_buf.items) orelse 0;
                    if (code == 52) {
                        self.handleOsc52(self.osc_buf.items);
                    }
                    if (isOscQuery(self.osc_buf.items)) {
                        if (!self.handleOscQuery(self.osc_buf.items, code)) {
                            self.osc_expect_response = true;
                            const stdout = std.fs.File.stdout();
                            stdout.writeAll(self.osc_buf.items) catch {};
                        }
                    } else {
                        const stdout = std.fs.File.stdout();
                        stdout.writeAll(self.osc_buf.items) catch {};
                    }
                }

                self.osc_buf.clearRetainingCapacity();
            }
        }
    }

    fn handleOscQuery(self: *Pane, seq: []const u8, code: u32) bool {
        _ = seq;
        if (!(code == 10 or code == 11 or code == 12)) return false;

        const color = switch (code) {
            10 => "ffff/ffff/ffff",
            11 => "0000/0000/0000",
            12 => "ffff/ffff/ffff",
            else => "0000/0000/0000",
        };

        var buf: [48]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{s}\x07", .{ code, color }) catch return true;
        self.write(resp) catch {};
        return true;
    }

    fn handleTerminalQueries(self: *Pane, data: []const u8) void {
        for (data) |b| {
            switch (self.query_state) {
                .idle => {
                    if (b == 0x1b) self.query_state = .esc;
                },
                .esc => {
                    if (b == '[') {
                        self.query_state = .csi;
                        self.query_len = 0;
                    } else if (b == 'P') {
                        self.query_state = .dcs;
                        self.query_len = 0;
                    } else {
                        self.query_state = .idle;
                    }
                },
                .csi => {
                    if (b >= 0x40 and b <= 0x7e) {
                        self.handleCsiQuery(b, self.query_buf[0..self.query_len]);
                        self.query_state = .idle;
                    } else if (self.query_len < self.query_buf.len) {
                        self.query_buf[self.query_len] = b;
                        self.query_len += 1;
                    } else {
                        self.query_state = .idle;
                    }
                },
                .dcs => {
                    if (b == 0x1b) {
                        self.query_state = .dcs_esc;
                    } else if (self.query_len < self.query_buf.len) {
                        self.query_buf[self.query_len] = b;
                        self.query_len += 1;
                    } else {
                        self.query_state = .idle;
                    }
                },
                .dcs_esc => {
                    if (b == '\\') {
                        self.handleDcsQuery(self.query_buf[0..self.query_len]);
                        self.query_state = .idle;
                    } else {
                        if (self.query_len + 2 <= self.query_buf.len) {
                            self.query_buf[self.query_len] = 0x1b;
                            self.query_len += 1;
                            self.query_buf[self.query_len] = b;
                            self.query_len += 1;
                            self.query_state = .dcs;
                        } else {
                            self.query_state = .idle;
                        }
                    }
                },
            }
        }
    }

    fn handleCsiQuery(self: *Pane, final: u8, params: []const u8) void {
        if (final == 'n') {
            var p = params;
            if (p.len > 0 and p[0] == '?') {
                p = p[1..];
            }
            if (p.len == 0) return;

            const first = std.mem.indexOfScalar(u8, p, ';') orelse p.len;
            const value = std.fmt.parseInt(u16, p[0..first], 10) catch return;

            if (value == 5 or value == 0 or value == 1) {
                self.write("\x1b[0n") catch {};
                return;
            }
            if (value == 6) {
                const cursor = self.vt.getCursor();
                var buf: [32]u8 = undefined;
                const row: u16 = cursor.y + 1;
                const col: u16 = cursor.x + 1;
                const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
                self.write(resp) catch {};
            }
            return;
        }

        if (final == 'c') {
            const is_secondary = params.len > 0 and params[0] == '>';
            var buf: [32]u8 = undefined;
            if (is_secondary) {
                const resp = std.fmt.bufPrint(&buf, "\x1b[>0;0;0c", .{}) catch return;
                self.write(resp) catch {};
            } else {
                const resp = std.fmt.bufPrint(&buf, "\x1b[?1;2c", .{}) catch return;
                self.write(resp) catch {};
            }
        }
    }

    fn handleDcsQuery(self: *Pane, params: []const u8) void {
        if (!std.mem.startsWith(u8, params, "$q")) return;
        const query = std.mem.trim(u8, params[2..], " ");

        if (std.mem.eql(u8, query, "q")) {
            const style = self.vt.getCursorStyle();
            var buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "\x1bP1$r q{d}\x1b\\", .{style}) catch return;
            self.write(resp) catch {};
            return;
        }

        if (std.mem.eql(u8, query, "m")) {
            self.write("\x1bP1$r 0m\x1b\\") catch {};
            return;
        }

        if (std.mem.eql(u8, query, "r")) {
            var buf: [64]u8 = undefined;
            const resp = std.fmt.bufPrint(&buf, "\x1bP1$r 1;{d}r\x1b\\", .{self.height}) catch return;
            self.write(resp) catch {};
        }
    }

    fn parseOscCode(seq: []const u8) ?u32 {
        if (seq.len < 4) return null;
        if (seq[0] != 0x1b or seq[1] != ']') return null;

        var i: usize = 2;
        var code: u32 = 0;
        var any: bool = false;
        while (i < seq.len) : (i += 1) {
            const c = seq[i];
            if (c == ';') break;
            if (c < '0' or c > '9') return null;
            any = true;
            code = code * 10 + @as(u32, c - '0');
            if (code > 10000) return null;
        }
        if (!any) return null;
        return code;
    }

    fn shouldPassthroughOsc(seq: []const u8) bool {
        const code = parseOscCode(seq) orelse return false;

        // For pywal + terminals that support it, we want the host terminal's
        // palette/default colors to be updated.
        if (code == 0 or code == 1 or code == 2) return true; // title/icon
        if (code == 7) return true; // cwd URL
        if (code == 52) return true; // clipboard

        // Color-related OSCs:
        // 4, 10-19, 104, 110-119
        if (code == 4 or code == 104) return true;
        if (code >= 10 and code <= 19) return true;
        if (code >= 110 and code <= 119) return true;

        // Notifications (OSC 9) can be spammy; keep disabled by default.
        return false;
    }

    fn isOscQuery(seq: []const u8) bool {
        const code = parseOscCode(seq) orelse return false;
        if (!(code == 4 or code == 104 or (code >= 10 and code <= 19) or (code >= 110 and code <= 119))) return false;
        // crude but effective: query forms include ";?"
        return std.mem.indexOf(u8, seq, ";?") != null;
    }

    fn handleOsc52(self: *Pane, seq: []const u8) void {
        // Parse: ESC ] 52 ; <sel> ; <base64> (BEL or ST)
        // We only support "set" (base64 payload), not query.
        const start = std.mem.indexOf(u8, seq, "\x1b]52;") orelse return;
        var i: usize = start + 5;

        // Skip selection up to next ';'
        const sel_end = std.mem.indexOfScalarPos(u8, seq, i, ';') orelse return;
        i = sel_end + 1;
        if (i >= seq.len) return;

        var payload = seq[i..];
        // Strip terminator.
        if (payload.len >= 2 and payload[payload.len - 2] == 0x1b and payload[payload.len - 1] == '\\') {
            payload = payload[0 .. payload.len - 2];
        } else if (payload.len >= 1 and payload[payload.len - 1] == 0x07) {
            payload = payload[0 .. payload.len - 1];
        }

        if (payload.len == 0 or (payload.len == 1 and payload[0] == '?')) return;

        // Decode base64.
        const decoder = std.base64.standard.Decoder;
        const out_len = decoder.calcSizeForSlice(payload) catch return;
        const decoded = self.allocator.alloc(u8, out_len) catch return;
        defer self.allocator.free(decoded);
        decoder.decode(decoded, payload) catch return;

        self.setSystemClipboard(decoded);
    }

    fn setSystemClipboard(self: *Pane, bytes: []const u8) void {
        // Best-effort. Prefer Wayland, then X11. Still passthrough to host.
        if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
            if (spawnClipboardWriter(self.allocator, &.{"wl-copy"}, bytes)) return;
        }
        if (std.posix.getenv("DISPLAY") != null) {
            if (spawnClipboardWriter(self.allocator, &.{ "xclip", "-selection", "clipboard", "-in" }, bytes)) return;
            if (spawnClipboardWriter(self.allocator, &.{ "xsel", "--clipboard", "--input" }, bytes)) return;
        }
    }

    fn spawnClipboardWriter(allocator: std.mem.Allocator, argv: []const []const u8, bytes: []const u8) bool {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return false;

        if (child.stdin) |stdin_file| {
            stdin_file.writeAll(bytes) catch {};
            stdin_file.close();
        }
        _ = child.wait() catch {};
        return true;
    }

    fn containsClearSeq(tail: []const u8, data: []const u8) bool {
        return std.mem.indexOfScalar(u8, data, 0x0c) != null or
            containsSeq(tail, data, "\x1b[2J") or
            containsSeq(tail, data, "\x1b[3J") or
            containsSeq(tail, data, "\x1b[J") or
            containsSeq(tail, data, "\x1b[0J") or
            containsSeq(tail, data, "\x1b[H\x1b[2J") or
            containsSeq(tail, data, "\x1b[H\x1b[J") or
            containsSeq(tail, data, "\x1b[H\x1b[0J") or
            containsSeq(tail, data, "\x1b[1;1H\x1b[2J") or
            containsSeq(tail, data, "\x1b[1;1H\x1b[J") or
            containsSeq(tail, data, "\x1b[1;1H\x1b[0J");
    }

    fn containsSeq(tail: []const u8, data: []const u8, seq: []const u8) bool {
        if (std.mem.indexOf(u8, data, seq) != null) return true;
        if (tail.len == 0) return false;

        const max_k = @min(tail.len, seq.len - 1);
        var k: usize = 1;
        while (k <= max_k) : (k += 1) {
            if (std.mem.eql(u8, tail[tail.len - k .. tail.len], seq[0..k]) and
                data.len >= seq.len - k and
                std.mem.eql(u8, data[0 .. seq.len - k], seq[k..seq.len]))
            {
                return true;
            }
        }

        return false;
    }

    /// Write input to backend.
    pub fn write(self: *Pane, data: []const u8) !void {
        switch (self.backend) {
            .local => |*pty| {
                _ = try pty.write(data);
            },
            .pod => |*pod| {
                pod_protocol.writeFrame(&pod.conn, .input, data) catch {};
            },
        }
    }

    /// Resize the pane
    pub fn resize(self: *Pane, x: u16, y: u16, width: u16, height: u16) !void {
        self.x = x;
        self.y = y;
        if (width != self.width or height != self.height) {
            self.width = width;
            self.height = height;
            try self.vt.resize(width, height);

            switch (self.backend) {
                .local => |*pty| try pty.setSize(width, height),
                .pod => self.sendResizeToPod(width, height),
            }
        }
    }

    fn sendResizeToPod(self: *Pane, cols: u16, rows: u16) void {
        switch (self.backend) {
            .pod => |*pod| {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u16, payload[0..2], cols, .big);
                std.mem.writeInt(u16, payload[2..4], rows, .big);
                pod_protocol.writeFrame(&pod.conn, .resize, &payload) catch {};
            },
            else => {},
        }
    }

    /// Get the backend file descriptor for polling
    pub fn getFd(self: *Pane) posix.fd_t {
        return switch (self.backend) {
            .local => |pty| pty.master_fd,
            .pod => |pod| pod.conn.fd,
        };
    }

    /// Check if pane is alive.
    pub fn isAlive(self: *Pane) bool {
        return switch (self.backend) {
            .local => |*pty| blk: {
                if (pty.pollStatus()) |status| {
                    self.exit_status = status;
                    break :blk false;
                }
                break :blk true;
            },
            .pod => true,
        };
    }

    pub fn getExitCode(self: *Pane) u8 {
        const status = self.exit_status orelse return 0;
        if (posix.W.IFEXITED(status)) return posix.W.EXITSTATUS(status);
        if (posix.W.IFSIGNALED(status)) return @intCast(128 + posix.W.TERMSIG(status));
        return 0;
    }

    pub fn captureOutput(self: *Pane, allocator: std.mem.Allocator) ![]u8 {
        if (self.capture_output and self.captured_output.items.len > 0) {
            return try extractLastLineFromOutput(allocator, self.captured_output.items);
        }

        const state = try self.getRenderState();
        const row_slice = state.row_data.slice();
        if (row_slice.len == 0 or state.cols == 0) {
            return allocator.dupe(u8, "");
        }

        const row_cells = row_slice.items(.cells);
        const rows = @min(@as(usize, state.rows), row_slice.len);

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(allocator);

        var ri: usize = rows;
        while (ri > 0) {
            ri -= 1;
            line_buf.clearRetainingCapacity();

            const cells_slice = row_cells[ri].slice();
            const raw_cells = cells_slice.items(.raw);
            const cols = @min(@as(usize, state.cols), raw_cells.len);

            for (0..cols) |ci| {
                const raw = raw_cells[ci];
                if (raw.wide == .spacer_tail) continue;

                var codepoint = raw.codepoint();
                if (codepoint == 0 or codepoint < 32 or codepoint == 127) {
                    codepoint = ' ';
                }

                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                    line_buf.append(allocator, ' ') catch {};
                    continue;
                };
                line_buf.appendSlice(allocator, utf8_buf[0..len]) catch {};
            }

            const trimmed = std.mem.trimRight(u8, line_buf.items, " ");
            if (trimmed.len > 0) {
                return allocator.dupe(u8, trimmed);
            }
        }

        return allocator.dupe(u8, "");
    }

    fn appendCapturedOutput(self: *Pane, data: []const u8) void {
        const MAX_CAPTURED_OUTPUT: usize = 1024 * 1024;
        if (data.len >= MAX_CAPTURED_OUTPUT) {
            self.captured_output.clearRetainingCapacity();
            const start = data.len - MAX_CAPTURED_OUTPUT;
            self.captured_output.appendSlice(self.allocator, data[start..]) catch {};
            return;
        }

        if (self.captured_output.items.len + data.len > MAX_CAPTURED_OUTPUT) {
            self.captured_output.clearRetainingCapacity();
        }

        self.captured_output.appendSlice(self.allocator, data) catch {};
    }

    fn extractLastLineFromOutput(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        if (try extractLastLineFromSlice(allocator, cropAfterAltScreenExit(data))) |line| {
            return line;
        }
        return (try extractLastLineFromSlice(allocator, data)) orelse allocator.dupe(u8, "");
    }

    fn extractLastLineFromSlice(allocator: std.mem.Allocator, slice: []const u8) !?[]u8 {
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(allocator);

        var i: usize = 0;
        while (i < slice.len) {
            const b = slice[i];
            if (b == 0x1b) {
                if (i + 1 < slice.len and slice[i + 1] == '[') {
                    i += 2;
                    while (i < slice.len) : (i += 1) {
                        const c = slice[i];
                        if (c >= 0x40 and c <= 0x7e) {
                            i += 1;
                            break;
                        }
                    }
                    continue;
                }
                if (i + 1 < slice.len and slice[i + 1] == ']') {
                    i += 2;
                    while (i < slice.len) : (i += 1) {
                        if (slice[i] == 0x07) {
                            i += 1;
                            break;
                        }
                        if (slice[i] == 0x1b and i + 1 < slice.len and slice[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                    continue;
                }
                if (i + 1 < slice.len and slice[i + 1] == 'P') {
                    i += 2;
                    while (i < slice.len) : (i += 1) {
                        if (slice[i] == 0x1b and i + 1 < slice.len and slice[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                    continue;
                }
                if (i + 1 < slice.len and (slice[i + 1] == 'G' or slice[i + 1] == '^' or slice[i + 1] == '_')) {
                    i += 2;
                    while (i < slice.len) : (i += 1) {
                        if (slice[i] == 0x1b and i + 1 < slice.len and slice[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                    }
                    continue;
                }
                i += 1;
                continue;
            }

            if (b == '\r') {
                try clean.append(allocator, '\n');
                i += 1;
                continue;
            }

            if (b == '\n' or b == '\t' or b >= 0x20) {
                try clean.append(allocator, b);
            }
            i += 1;
        }

        var it = std.mem.splitScalar(u8, clean.items, '\n');
        var last: []const u8 = "";
        while (it.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, " ");
            if (trimmed.len > 0) last = trimmed;
        }
        if (last.len == 0) return null;
        return @as(?[]u8, try allocator.dupe(u8, last));
    }

    fn cropAfterAltScreenExit(data: []const u8) []const u8 {
        const seqs = [_][]const u8{
            "\x1b[?1049l",
            "\x1b[?47l",
            "\x1b[?1047l",
        };

        var max_idx: ?usize = null;
        for (seqs) |seq| {
            if (std.mem.lastIndexOf(u8, data, seq)) |idx| {
                const end = idx + seq.len;
                if (max_idx == null or end > max_idx.?) {
                    max_idx = end;
                }
            }
        }

        if (max_idx) |start| {
            if (start < data.len) return data[start..];
        }
        return data;
    }

    /// Get the underlying ghostty terminal.
    pub fn getTerminal(self: *Pane) *ghostty.Terminal {
        return &self.vt.terminal;
    }

    /// Get a stable snapshot of the viewport for rendering.
    pub fn getRenderState(self: *Pane) !*const ghostty.RenderState {
        return self.vt.getRenderState();
    }

    /// Get cursor position relative to screen
    pub fn getCursorPos(self: *Pane) struct { x: u16, y: u16 } {
        const cursor = self.vt.getCursor();
        return .{ .x = self.x + cursor.x, .y = self.y + cursor.y };
    }

    /// Get cursor style (DECSCUSR value)
    pub fn getCursorStyle(self: *Pane) u8 {
        return self.vt.getCursorStyle();
    }

    /// Check if cursor should be visible
    pub fn isCursorVisible(self: *Pane) bool {
        return self.vt.isCursorVisible();
    }

    // Static buffers for proc reads
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var proc_buf: [256]u8 = undefined;

    /// Get current working directory (from OSC 7)
    pub fn getPwd(self: *Pane) ?[]const u8 {
        return self.vt.getPwd();
    }

    /// Get best available current working directory.
    /// Tries OSC 7 first (most reliable and up-to-date), then falls back
    /// to local /proc/<pid>/cwd (works for local PTY panes), then falls back
    /// to cached CWD from ses (works for pod panes where mux can't read /proc).
    pub fn getRealCwd(self: *Pane) ?[]const u8 {
        // Try OSC 7 first (works for both local and pod panes)
        if (self.vt.getPwd()) |pwd| {
            return pwd;
        }

        // Try local /proc fallback (works for local PTY panes)
        if (self.getFgPid()) |pid| {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid}) catch return self.ses_cwd;
            const link = std.posix.readlink(path, &cwd_buf) catch return self.ses_cwd;
            return link;
        }

        // For pod panes, use cached CWD from ses daemon (populated by main.zig)
        return self.ses_cwd;
    }

    extern fn tcgetpgrp(fd: c_int) posix.pid_t;

    /// Get foreground process group PID using tcgetpgrp.
    /// Only available for local PTY panes.
    pub fn getFgPid(self: *Pane) ?posix.pid_t {
        const fd = switch (self.backend) {
            .local => |pty| pty.master_fd,
            .pod => return null,
        };

        const pgrp = tcgetpgrp(fd);
        if (pgrp < 0) return null;
        return pgrp;
    }

    /// Get foreground process name by reading /proc/<pid>/comm.
    /// Only available for local PTY panes.
    pub fn getFgProcess(self: *Pane) ?[]const u8 {
        const pid = self.getFgPid() orelse return null;
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
        const file = std.fs.openFileAbsolute(path, .{}) catch return null;
        defer file.close();
        const len = file.read(&proc_buf) catch return null;
        if (len == 0) return null;
        const end = if (len > 0 and proc_buf[len - 1] == '\n') len - 1 else len;
        return proc_buf[0..end];
    }

    /// Scroll up by given number of lines
    pub fn scrollUp(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(lines)) }) catch {};
    }

    /// Scroll down by given number of lines
    pub fn scrollDown(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = @as(isize, @intCast(lines)) }) catch {};
    }

    /// Scroll to top of history
    pub fn scrollToTop(self: *Pane) void {
        self.vt.terminal.scrollViewport(.top) catch {};
    }

    /// Scroll to bottom (current output)
    pub fn scrollToBottom(self: *Pane) void {
        self.vt.terminal.scrollViewport(.bottom) catch {};
    }

    /// Check if we're scrolled (not at bottom)
    pub fn isScrolled(self: *Pane) bool {
        return !self.vt.terminal.screens.active.viewportIsBottom();
    }

    /// Show a notification on this pane
    pub fn showNotification(self: *Pane, message: []const u8) void {
        if (self.notifications_initialized) {
            self.notifications.show(message);
        }
    }

    /// Show a notification with custom duration
    pub fn showNotificationFor(self: *Pane, message: []const u8, duration_ms: i64) void {
        if (self.notifications_initialized) {
            self.notifications.showFor(message, duration_ms);
        }
    }

    /// Update notifications (call each frame)
    pub fn updateNotifications(self: *Pane) bool {
        if (self.notifications_initialized) {
            return self.notifications.update();
        }
        return false;
    }

    /// Update popups (call each frame) - checks for timeout
    pub fn updatePopups(self: *Pane) bool {
        if (self.popups_initialized) {
            return self.popups.update();
        }
        return false;
    }

    /// Check if pane has active notification
    pub fn hasActiveNotification(self: *Pane) bool {
        if (self.notifications_initialized) {
            return self.notifications.hasActive();
        }
        return false;
    }

    /// Configure notifications from config
    pub fn configureNotifications(self: *Pane, cfg: anytype) void {
        if (self.notifications_initialized) {
            self.notifications.default_style = notification.Style.fromConfig(cfg);
            self.notifications.default_duration_ms = @intCast(cfg.duration_ms);
        }
    }

    /// Configure notifications from pop.NotificationStyle config
    pub fn configureNotificationsFromPop(self: *Pane, cfg: anytype) void {
        if (self.notifications_initialized) {
            const align_val: notification.Align = if (std.mem.eql(u8, cfg.alignment, "left")) .left else if (std.mem.eql(u8, cfg.alignment, "right")) .right else .center;

            self.notifications.default_style = .{
                .fg = .{ .palette = cfg.fg },
                .bg = .{ .palette = cfg.bg },
                .bold = cfg.bold,
                .padding_x = cfg.padding_x,
                .padding_y = cfg.padding_y,
                .offset = cfg.offset,
                .alignment = align_val,
            };
            self.notifications.default_duration_ms = @intCast(cfg.duration_ms);
        }
    }
};
