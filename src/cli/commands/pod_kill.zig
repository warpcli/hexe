const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;

const print = std.debug.print;

pub fn runPodKill(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8, signal_name: []const u8, force: bool) !void {
    const pid = try resolvePodPid(allocator, uuid, name);
    if (pid == null) {
        print("pod not found\n", .{});
        return;
    }

    const sig = parseSignal(signal_name);
    if (sig == null) {
        print("Error: invalid --signal\n", .{});
        return;
    }

    const rc = std.c.kill(@intCast(pid.?), sig.?);
    if (rc != 0) {
        // errno not surfaced here in a nice way; keep message simple.
        print("kill failed\n", .{});
        return;
    }

    if (force and sig.? != std.c.SIG.KILL) {
        // best-effort SIGKILL after short delay
        std.Thread.sleep(50 * std.time.ns_per_ms);
        _ = std.c.kill(@intCast(pid.?), std.c.SIG.KILL);
    }
}

fn parseSignal(name: []const u8) ?c_int {
    if (name.len == 0) return std.c.SIG.TERM;
    if (std.mem.eql(u8, name, "TERM") or std.mem.eql(u8, name, "SIGTERM")) return std.c.SIG.TERM;
    if (std.mem.eql(u8, name, "KILL") or std.mem.eql(u8, name, "SIGKILL")) return std.c.SIG.KILL;
    if (std.mem.eql(u8, name, "INT") or std.mem.eql(u8, name, "SIGINT")) return std.c.SIG.INT;
    if (std.mem.eql(u8, name, "HUP") or std.mem.eql(u8, name, "SIGHUP")) return std.c.SIG.HUP;
    return null;
}

fn resolvePodPid(allocator: std.mem.Allocator, uuid: []const u8, name: []const u8) !?i64 {
    // If uuid is provided, we can just read the .meta file for pid.
    if (uuid.len > 0) {
        if (uuid.len != 32) return error.InvalidUuid;
        const dir = try ipc.getSocketDir(allocator);
        defer allocator.free(dir);
        const path = try std.fmt.allocPrint(allocator, "{s}/pod-{s}.meta", .{ dir, uuid });
        defer allocator.free(path);
        return readPidFromMeta(path);
    }
    if (name.len == 0) return null;

    // Scan all meta files; pick newest created_at for matching name.
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var best_pid: ?i64 = null;
    var best_created_at: i64 = -1;

    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "pod-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
        defer allocator.free(full);

        var f = d.openFile(entry.name, .{}) catch continue;
        defer f.close();
        var buf: [4096]u8 = undefined;
        const n = f.readAll(&buf) catch continue;
        if (n == 0) continue;
        const line = std.mem.trim(u8, buf[0..n], " \t\n\r");
        if (!std.mem.startsWith(u8, line, pod_meta.POD_META_PREFIX)) continue;
        const nm = parseField(line, "name") orelse continue;
        if (!std.mem.eql(u8, nm, name)) continue;
        const pid_s = parseField(line, "pid") orelse continue;
        const pid = std.fmt.parseInt(i64, pid_s, 10) catch continue;
        const ca = parseField(line, "created_at") orelse "0";
        const created_at = std.fmt.parseInt(i64, ca, 10) catch 0;
        if (created_at >= best_created_at) {
            best_created_at = created_at;
            best_pid = pid;
        }
    }

    return best_pid;
}

fn readPidFromMeta(path: []const u8) ?i64 {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.readAll(&buf) catch return null;
    if (n == 0) return null;
    const line = std.mem.trim(u8, buf[0..n], " \t\n\r");
    if (!std.mem.startsWith(u8, line, pod_meta.POD_META_PREFIX)) return null;
    const pid_s = parseField(line, "pid") orelse return null;
    return std.fmt.parseInt(i64, pid_s, 10) catch null;
}

fn parseField(line: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 2 > pat_buf.len) return null;
    pat_buf[0] = ' ';
    @memcpy(pat_buf[1 .. 1 + key.len], key);
    pat_buf[1 + key.len] = '=';
    const pat = pat_buf[0 .. 2 + key.len];
    const start = std.mem.indexOf(u8, line, pat) orelse return null;
    const val_start = start + pat.len;
    const rest = line[val_start..];
    const end_rel = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end_rel];
}
