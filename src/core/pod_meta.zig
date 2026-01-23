const std = @import("std");
const ipc = @import("ipc.zig");

pub const POD_META_PREFIX: []const u8 = "HEXE_POD";

pub const PodMeta = struct {
    /// Canonical pod identity (32 lowercase hex).
    uuid: [32]u8,

    /// Human-friendly name (best-effort, optional).
    name: ?[]const u8 = null,

    /// Pod PID (the `hexe pod daemon` process).
    pid: std.posix.pid_t,

    /// Child PID (the spawned shell/process inside PTY).
    child_pid: std.posix.pid_t,

    /// Working directory passed at spawn time (optional).
    cwd: ?[]const u8 = null,

    /// Current isolation state (future-proof; today pods are not isolated).
    isolated: bool = false,

    /// Comma-separated label list stored as owned strings.
    labels: []const []const u8 = &[_][]const u8{},

    /// Unix timestamp seconds when pod was created.
    created_at: i64,

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        uuid_str: []const u8,
        name: ?[]const u8,
        pid: std.posix.pid_t,
        child_pid: std.posix.pid_t,
        cwd: ?[]const u8,
        isolated: bool,
        labels_csv: ?[]const u8,
        created_at: i64,
    ) !PodMeta {
        if (uuid_str.len != 32) return error.InvalidUuid;

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const owned_name: ?[]const u8 = if (name) |n| if (n.len > 0) try allocator.dupe(u8, n) else null else null;
        errdefer if (owned_name) |n| allocator.free(n);

        const owned_cwd: ?[]const u8 = if (cwd) |d| if (d.len > 0) try allocator.dupe(u8, d) else null else null;
        errdefer if (owned_cwd) |d| allocator.free(d);

        const labels = try parseLabelsCsv(allocator, labels_csv);
        errdefer freeLabels(allocator, labels);

        return .{
            .uuid = uuid,
            .name = owned_name,
            .pid = pid,
            .child_pid = child_pid,
            .cwd = owned_cwd,
            .isolated = isolated,
            .labels = labels,
            .created_at = created_at,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PodMeta) void {
        if (self.name) |n| self.allocator.free(n);
        if (self.cwd) |d| self.allocator.free(d);
        freeLabels(self.allocator, self.labels);
        self.* = undefined;
    }

    pub fn socketDir(allocator: std.mem.Allocator) ![]const u8 {
        return ipc.getSocketDir(allocator);
    }

    pub fn socketPath(self: *const PodMeta, allocator: std.mem.Allocator) ![]const u8 {
        return ipc.getPodSocketPath(allocator, &self.uuid);
    }

    pub fn metaPath(self: *const PodMeta, allocator: std.mem.Allocator) ![]const u8 {
        const dir = try ipc.getSocketDir(allocator);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/pod-{s}.meta", .{ dir, self.uuid[0..] });
    }

    pub fn aliasSocketPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        const dir = try ipc.getSocketDir(allocator);
        defer allocator.free(dir);
        var sanitized_buf: [64]u8 = undefined;
        const sanitized = sanitizeNameForAlias(&sanitized_buf, name);
        return std.fmt.allocPrint(allocator, "{s}/pod@{s}.sock", .{ dir, sanitized });
    }

    pub fn formatMetaLine(self: *const PodMeta, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print("{s} uuid={s}", .{ POD_META_PREFIX, self.uuid[0..] });

        if (self.name) |n| {
            try w.print(" name={s}", .{n});
        } else {
            try w.writeAll(" name=");
        }

        try w.print(" pid={d} child_pid={d}", .{ self.pid, self.child_pid });

        if (self.cwd) |d| {
            try w.print(" cwd={s}", .{d});
        } else {
            try w.writeAll(" cwd=");
        }

        try w.print(" isolated={d}", .{if (self.isolated) @as(u8, 1) else 0});

        // labels=a,b,c
        try w.writeAll(" labels=");
        for (self.labels, 0..) |lab, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(lab);
        }

        try w.print(" created_at={d}", .{self.created_at});
        return buf.toOwnedSlice(allocator);
    }
};

fn freeLabels(allocator: std.mem.Allocator, labels: []const []const u8) void {
    for (labels) |lab| allocator.free(lab);
    allocator.free(labels);
}

fn parseLabelsCsv(allocator: std.mem.Allocator, labels_csv: ?[]const u8) ![]const []const u8 {
    if (labels_csv == null) return &[_][]const u8{};
    const csv = std.mem.trim(u8, labels_csv.?, " \t\n\r");
    if (csv.len == 0) return &[_][]const u8{};

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |lab| allocator.free(lab);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t\n\r");
        if (t.len == 0) continue;
        // Keep labels conservative: [A-Za-z0-9_.-]
        var ok = true;
        for (t) |ch| {
            const allowed = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
            if (!allowed) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        try list.append(allocator, try allocator.dupe(u8, t));
    }

    return list.toOwnedSlice(allocator);
}

pub fn sanitizeNameForAlias(out: []u8, raw: []const u8) []const u8 {
    // Similar to instance name sanitization but allow a bit longer.
    const max_len: usize = @min(out.len, 48);
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= max_len) break;
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        out[n] = if (ok) ch else '_';
        n += 1;
    }
    if (n == 0) {
        out[0] = 'p';
        out[1] = 'o';
        out[2] = 'd';
        return out[0..3];
    }
    return out[0..n];
}
