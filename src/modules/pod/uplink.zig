const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const core = @import("core");
const wire = core.wire;

pub const PodUplink = struct {
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    fd: ?posix.fd_t = null,
    last_sent_ms: i64 = 0,
    last_cwd: ?[]u8 = null,
    last_fg_process: ?[]u8 = null,
    last_fg_pid: ?i32 = null,

    pub fn init(allocator: std.mem.Allocator, uuid: [32]u8) PodUplink {
        return .{ .allocator = allocator, .uuid = uuid };
    }

    pub fn deinit(self: *PodUplink) void {
        if (self.fd) |fd| posix.close(fd);
        if (self.last_cwd) |s| self.allocator.free(s);
        if (self.last_fg_process) |s| self.allocator.free(s);
        self.* = undefined;
    }

    pub fn tick(self: *PodUplink, child_pid: posix.pid_t) void {
        const now_ms: i64 = std.time.milliTimestamp();
        if (now_ms - self.last_sent_ms < 100) return;
        self.last_sent_ms = now_ms;

        const proc_cwd = readProcCwd(self.allocator, child_pid) catch null;
        defer if (proc_cwd) |s| self.allocator.free(s);

        const fg = readProcForeground(self.allocator, child_pid) catch null;
        defer if (fg) |v| {
            self.allocator.free(v.name);
        };

        var changed = false;
        if (!optStrEql(self.last_cwd, proc_cwd)) changed = true;
        const fg_name = if (fg) |v| v.name else null;
        const fg_pid = if (fg) |v| v.pid else null;
        if (!optStrEql(self.last_fg_process, fg_name)) changed = true;
        if (!optIntEql(i32, self.last_fg_pid, fg_pid)) changed = true;
        if (!changed) return;

        if (self.last_cwd) |s| self.allocator.free(s);
        self.last_cwd = if (proc_cwd) |s| self.allocator.dupe(u8, s) catch null else null;

        if (self.last_fg_process) |s| self.allocator.free(s);
        self.last_fg_process = if (fg_name) |s| self.allocator.dupe(u8, s) catch null else null;
        self.last_fg_pid = fg_pid;

        if (!self.ensureConnected()) return;
        const fd = self.fd.?;

        if (proc_cwd) |cwd_str| {
            var cwd_msg: wire.CwdChanged = .{
                .uuid = self.uuid,
                .cwd_len = @intCast(@min(cwd_str.len, std.math.maxInt(u16))),
            };
            const trails = [_][]const u8{cwd_str[0..cwd_msg.cwd_len]};
            wire.writeControlMsg(fd, .cwd_changed, std.mem.asBytes(&cwd_msg), &trails) catch {
                self.disconnect();
                return;
            };
        }

        if (fg_name) |name_str| {
            var fg_msg: wire.FgChanged = .{
                .uuid = self.uuid,
                .pid = fg_pid orelse 0,
                .name_len = @intCast(@min(name_str.len, std.math.maxInt(u16))),
            };
            const trails = [_][]const u8{name_str[0..fg_msg.name_len]};
            wire.writeControlMsg(fd, .fg_changed, std.mem.asBytes(&fg_msg), &trails) catch {
                self.disconnect();
                return;
            };
        }
    }

    pub fn ensureConnected(self: *PodUplink) bool {
        if (self.fd != null) return true;

        const ses_path = core.ipc.getSesSocketPath(self.allocator) catch return false;
        defer self.allocator.free(ses_path);

        const client = core.ipc.Client.connect(ses_path) catch return false;
        const fd = client.fd;

        var handshake: [18]u8 = undefined;
        handshake[0] = wire.SES_HANDSHAKE_POD_CTL;
        handshake[1] = wire.PROTOCOL_VERSION;

        const uuid_bin = core.uuid.hexToBin(self.uuid) orelse {
            posix.close(fd);
            return false;
        };
        @memcpy(handshake[2..18], &uuid_bin);
        wire.writeAll(fd, &handshake) catch {
            posix.close(fd);
            return false;
        };

        self.fd = fd;
        return true;
    }

    pub fn disconnect(self: *PodUplink) void {
        if (self.fd) |fd| posix.close(fd);
        self.fd = null;
    }
};

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn optIntEql(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn readProcCwd(allocator: std.mem.Allocator, pid: posix.pid_t) !?[]u8 {
    if (pid <= 0) return null;
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid});
    var tmp: [std.fs.max_path_bytes]u8 = undefined;
    const link = posix.readlink(path, &tmp) catch return null;
    return try allocator.dupe(u8, link);
}

fn readProcForeground(allocator: std.mem.Allocator, child_pid: posix.pid_t) !?struct { name: []u8, pid: i32 } {
    if (child_pid <= 0) return null;

    var stat_path_buf: [64]u8 = undefined;
    const stat_path = try std.fmt.bufPrint(&stat_path_buf, "/proc/{d}/stat", .{child_pid});
    const stat_file = std.fs.openFileAbsolute(stat_path, .{}) catch return null;
    defer stat_file.close();

    var stat_buf: [512]u8 = undefined;
    const stat_len = stat_file.read(&stat_buf) catch return null;
    if (stat_len == 0) return null;
    const stat = stat_buf[0..stat_len];

    const right_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    if (right_paren + 2 >= stat.len) return null;
    const rest = stat[right_paren + 2 ..];

    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var idx: usize = 0;
    var tpgid: ?i32 = null;
    while (it.next()) |tok| {
        idx += 1;
        if (idx == 6) {
            const v = std.fmt.parseInt(i32, tok, 10) catch return null;
            if (v > 0) tpgid = v;
            break;
        }
    }
    if (tpgid == null) return null;

    var comm_path_buf: [64]u8 = undefined;
    const comm_path = try std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{tpgid.?});
    const comm_file = std.fs.openFileAbsolute(comm_path, .{}) catch return null;
    defer comm_file.close();
    var comm_buf: [128]u8 = undefined;
    const comm_len = comm_file.read(&comm_buf) catch return null;
    if (comm_len == 0) return null;
    const end = if (comm_buf[comm_len - 1] == '\n') comm_len - 1 else comm_len;

    const name = try allocator.dupe(u8, comm_buf[0..end]);
    return .{ .name = name, .pid = tpgid.? };
}
