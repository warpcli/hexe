const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;

const print = std.debug.print;

pub fn runPodGc(allocator: std.mem.Allocator, dry_run: bool) !void {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();

    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "pod-") and std.mem.endsWith(u8, entry.name, ".meta")) {
            // If socket missing or not connectable, delete meta.
            const uuid = extractUuidFromMetaFilename(entry.name) orelse continue;
            const sock = try ipc.getPodSocketPath(allocator, uuid);
            defer allocator.free(sock);
            const alive = (ipc.Client.connect(sock) catch null) != null;
            if (!alive) {
                if (dry_run) {
                    print("gc: would delete {s}/{s}\n", .{ dir, entry.name });
                } else {
                    d.deleteFile(entry.name) catch {};
                    print("gc: deleted {s}/{s}\n", .{ dir, entry.name });
                }
            }
            continue;
        }

        if (entry.kind == .sym_link and std.mem.startsWith(u8, entry.name, "pod@") and std.mem.endsWith(u8, entry.name, ".sock")) {
            // If link is broken or target not connectable, delete it.
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = d.readLink(entry.name, &link_buf) catch "";
            if (target.len == 0) {
                if (dry_run) {
                    print("gc: would delete {s}/{s}\n", .{ dir, entry.name });
                } else {
                    d.deleteFile(entry.name) catch {};
                    print("gc: deleted {s}/{s}\n", .{ dir, entry.name });
                }
                continue;
            }
            // Try connect to link path itself (more robust than resolving).
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
            defer allocator.free(full);
            const alive = (ipc.Client.connect(full) catch null) != null;
            if (!alive) {
                if (dry_run) {
                    print("gc: would delete {s}\n", .{full});
                } else {
                    d.deleteFile(entry.name) catch {};
                    print("gc: deleted {s}\n", .{full});
                }
            }
            continue;
        }
    }

    _ = pod_meta;
}

fn extractUuidFromMetaFilename(name: []const u8) ?[]const u8 {
    // "pod-<uuid>.meta"
    if (!std.mem.startsWith(u8, name, "pod-")) return null;
    if (!std.mem.endsWith(u8, name, ".meta")) return null;
    const mid = name[4 .. name.len - 5];
    if (mid.len != 32) return null;
    return mid;
}
