const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ghostty = @import("ghostty-vt");
const pod_protocol = core.pod_protocol;
const wire = core.wire;

const pane_capture = @import("pane_capture.zig");

const notification = @import("notification.zig");
const NotificationManager = notification.NotificationManager;
const pop = @import("pop");

const QueryState = enum {
    idle,
    esc,
    csi,
    dcs,
    dcs_esc,
};

const Backend = union(enum) {
    local: core.Pty,
    /// Pod-backed pane — VT routed through SES.
    pod: struct {
        pane_id: u16,
        vt_fd: posix.fd_t, // shared MUX VT channel fd
        dead: bool = false,
    },
};

/// A Pane is a ghostty VT that receives bytes via the SES VT channel
/// (pod-backed, persistent scrollback).
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
    // Dim background when this float is visible (focus mode)
    dim_background: bool = false,
    // Exit key for adhoc floats (close float when this key is pressed)
    exit_key: ?[]const u8 = null,
    // For tab-bound floats: which tab owns this float
    // null = global float (special=true or pwd=true)
    parent_tab: ?usize = null,
    // Border style and optional module
    float_style: ?*const core.FloatStyle = null,
    float_title: ?[]u8 = null,

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

    pub fn toggleVisibleOnTab(self: *Pane, tab: usize) void {
        self.setVisibleOnTab(tab, !self.isVisibleOnTab(tab));
    }

    pub fn init(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16) !void {
        return self.initWithCommand(allocator, id, x, y, width, height, null, null, null);
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
        extra_env: ?[]const []const u8,
    ) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height };

        const cmd = command orelse (posix.getenv("SHELL") orelse "/bin/sh");
        var env_pairs: ?[]const [2][]const u8 = null;
        defer if (env_pairs) |pairs| allocator.free(pairs);

        var pty = if (extra_env) |env_lines| blk: {
            env_pairs = try buildEnvPairs(allocator, env_lines);
            break :blk try core.Pty.spawnWithEnv(cmd, cwd, env_pairs);
        } else try core.Pty.spawnWithCwd(cmd, cwd);
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
    /// VT data is routed through the SES VT channel.
    pub fn initWithPod(self: *Pane, allocator: std.mem.Allocator, id: u16, x: u16, y: u16, width: u16, height: u16, pane_id: u16, vt_fd: posix.fd_t, uuid: [32]u8) !void {
        self.* = .{ .allocator = allocator, .id = id, .x = x, .y = y, .width = width, .height = height, .uuid = uuid };

        self.backend = .{ .pod = .{ .pane_id = pane_id, .vt_fd = vt_fd } };

        try self.vt.init(allocator, width, height);
        errdefer self.vt.deinit();

        self.notifications = NotificationManager.init(allocator);
        self.notifications_initialized = true;
        self.popups = pop.PopupManager.init(allocator);
        self.popups_initialized = true;

        // Tell pod initial size via VT channel.
        self.sendResizeToPod(width, height);
    }

    pub fn deinit(self: *Pane) void {
        switch (self.backend) {
            .local => |*pty| pty.close(),
            .pod => {}, // VT channel is shared, not owned by pane
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
        if (self.float_title) |t| {
            self.allocator.free(t);
            self.float_title = null;
        }
    }

    fn buildEnvPairs(allocator: std.mem.Allocator, lines: []const []const u8) ![]const [2][]const u8 {
        var pairs: std.ArrayList([2][]const u8) = .empty;
        errdefer pairs.deinit(allocator);

        for (lines) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (eq == 0 or eq + 1 > line.len) continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            try pairs.append(allocator, .{ key, value });
        }

        return pairs.toOwnedSlice(allocator);
    }

    /// Set cached CWD from ses daemon (for pod panes)
    pub fn setSesCwd(self: *Pane, cwd: ?[]u8) void {
        if (self.ses_cwd) |old| {
            self.allocator.free(old);
        }
        self.ses_cwd = cwd;
    }

    /// Replace backend with a pod (used during reattach to adopt panes).
    pub fn replaceWithPod(self: *Pane, pane_id: u16, vt_fd: posix.fd_t, uuid: [32]u8) !void {
        // Close old backend.
        switch (self.backend) {
            .local => |*pty| pty.close(),
            .pod => {},
        }

        self.uuid = uuid;
        self.backend = .{ .pod = .{ .pane_id = pane_id, .vt_fd = vt_fd } };

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

    /// Read from local backend and feed to VT. Returns true if data was read.
    /// For pod panes, output comes from the VT channel (see feedPodOutput).
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
            .pod => false, // Pod panes don't poll — data comes via feedPodOutput
        };
    }

    /// Feed output data received from the SES VT channel.
    /// Called by the event loop when a MuxVtHeader frame arrives for this pane.
    pub fn feedPodOutput(self: *Pane, data: []const u8) void {
        self.did_clear = false;
        self.processOutput(data);
        self.vt.feed(data) catch {};
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

        if (code == 0 or code == 1 or code == 2) return true;
        if (code == 7) return true;
        if (code == 52) return true;
        if (code == 4 or code == 104) return true;
        if (code >= 10 and code <= 19) return true;
        if (code >= 110 and code <= 119) return true;
        return false;
    }

    fn isOscQuery(seq: []const u8) bool {
        const code = parseOscCode(seq) orelse return false;
        if (!(code == 4 or code == 104 or (code >= 10 and code <= 19) or (code >= 110 and code <= 119))) return false;
        return std.mem.indexOf(u8, seq, ";?") != null;
    }

    fn handleOsc52(self: *Pane, seq: []const u8) void {
        const start = std.mem.indexOf(u8, seq, "\x1b]52;") orelse return;
        var i: usize = start + 5;

        const sel_end = std.mem.indexOfScalarPos(u8, seq, i, ';') orelse return;
        i = sel_end + 1;
        if (i >= seq.len) return;

        var payload = seq[i..];
        if (payload.len >= 2 and payload[payload.len - 2] == 0x1b and payload[payload.len - 1] == '\\') {
            payload = payload[0 .. payload.len - 2];
        } else if (payload.len >= 1 and payload[payload.len - 1] == 0x07) {
            payload = payload[0 .. payload.len - 1];
        }

        if (payload.len == 0 or (payload.len == 1 and payload[0] == '?')) return;

        const decoder = std.base64.standard.Decoder;
        const out_len = decoder.calcSizeForSlice(payload) catch return;
        const decoded = self.allocator.alloc(u8, out_len) catch return;
        defer self.allocator.free(decoded);
        decoder.decode(decoded, payload) catch return;

        self.setSystemClipboard(decoded);
    }

    fn setSystemClipboard(self: *Pane, bytes: []const u8) void {
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
        const has_esc = std.mem.indexOfScalar(u8, data, 0x1b) != null;
        const has_ff = std.mem.indexOfScalar(u8, data, 0x0c) != null;
        const tail_has_esc = tail.len > 0 and tail[tail.len - 1] == 0x1b;
        if (!has_esc and !has_ff and !tail_has_esc) return false;

        return has_ff or
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
            .pod => |pod| {
                // Send input through SES VT channel as MuxVtHeader frame.
                const frame_type = @intFromEnum(pod_protocol.FrameType.input);
                wire.writeMuxVt(pod.vt_fd, pod.pane_id, frame_type, data) catch {};
            },
        }
    }

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
            .pod => |pod| {
                var payload: [4]u8 = undefined;
                std.mem.writeInt(u16, payload[0..2], cols, .big);
                std.mem.writeInt(u16, payload[2..4], rows, .big);
                const frame_type = @intFromEnum(pod_protocol.FrameType.resize);
                wire.writeMuxVt(pod.vt_fd, pod.pane_id, frame_type, &payload) catch {};
            },
            else => {},
        }
    }

    pub fn getFd(self: *Pane) posix.fd_t {
        return switch (self.backend) {
            .local => |pty| pty.master_fd,
            .pod => -1, // Pod panes don't have their own fd
        };
    }

    /// Whether this pane has a pollable fd (local panes only).
    pub fn hasPollableFd(self: *const Pane) bool {
        return switch (self.backend) {
            .local => true,
            .pod => false,
        };
    }

    pub fn isAlive(self: *Pane) bool {
        return switch (self.backend) {
            .local => |*pty| blk: {
                if (pty.pollStatus()) |status| {
                    self.exit_status = status;
                    break :blk false;
                }
                break :blk true;
            },
            .pod => |pod| !pod.dead,
        };
    }

    pub fn getExitCode(self: *Pane) u8 {
        const status = self.exit_status orelse return 0;
        if (posix.W.IFEXITED(status)) return posix.W.EXITSTATUS(status);
        if (posix.W.IFSIGNALED(status)) return @intCast(128 + posix.W.TERMSIG(status));
        return 0;
    }

    pub fn captureOutput(self: *Pane, allocator: std.mem.Allocator) ![]u8 {
        return pane_capture.captureOutput(self, allocator);
    }

    fn appendCapturedOutput(self: *Pane, data: []const u8) void {
        pane_capture.appendCapturedOutput(self, data);
    }

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
    pub fn getRealCwd(self: *Pane) ?[]const u8 {
        if (self.vt.getPwd()) |pwd| {
            return pwd;
        }

        if (self.getFgPid()) |pid| {
            var path_buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid}) catch return self.ses_cwd;
            const link = std.posix.readlink(path, &cwd_buf) catch return self.ses_cwd;
            return link;
        }

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

    /// Get the pane_id for pod-backed panes (used for VT routing).
    pub fn getPaneId(self: *const Pane) ?u16 {
        return switch (self.backend) {
            .pod => |pod| pod.pane_id,
            .local => null,
        };
    }

    /// Scroll up by given number of lines
    pub fn scrollUp(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(lines)) }) catch {};
        self.vt.invalidateRenderState();
    }

    /// Scroll down by given number of lines
    pub fn scrollDown(self: *Pane, lines: u32) void {
        self.vt.terminal.scrollViewport(.{ .delta = @as(isize, @intCast(lines)) }) catch {};
        self.vt.invalidateRenderState();
    }

    /// Scroll to top of history
    pub fn scrollToTop(self: *Pane) void {
        self.vt.terminal.scrollViewport(.top) catch {};
        self.vt.invalidateRenderState();
    }

    /// Scroll to bottom (current output)
    pub fn scrollToBottom(self: *Pane) void {
        self.vt.terminal.scrollViewport(.bottom) catch {};
        self.vt.invalidateRenderState();
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
