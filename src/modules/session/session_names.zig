const std = @import("std");
const store_mod = @import("store.zig");
const core = @import("core");

pub fn isSessionNameInUse(
    store: *const store_mod.SessionStore,
    name: []const u8,
    exclude_client_id: ?usize,
    exclude_session_id: ?[16]u8,
) bool {
    var iter = store.detached_sessions.iterator();
    while (iter.next()) |entry| {
        if (exclude_session_id) |exclude| {
            if (std.mem.eql(u8, &entry.key_ptr.*, &exclude)) continue;
        }
        const detached = entry.value_ptr;
        if (std.ascii.eqlIgnoreCase(detached.session_snapshot.session_name, name)) {
            return true;
        }
    }

    for (store.clients.items) |*client| {
        if (exclude_client_id) |exclude| {
            if (client.id == exclude) continue;
        }
        if (client.session_name) |client_name| {
            if (std.ascii.eqlIgnoreCase(client_name, name)) {
                return true;
            }
        }
    }
    return false;
}

pub fn resolveSessionName(
    allocator: std.mem.Allocator,
    store: *const store_mod.SessionStore,
    requested_name: []const u8,
    exclude_client_id: ?usize,
    exclude_session_id: ?[16]u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, requested_name, " \t\r\n");
    const base_name = if (trimmed.len > 0) trimmed else "session";

    if (!isSessionNameInUse(store, base_name, exclude_client_id, exclude_session_id)) {
        return try allocator.dupe(u8, base_name);
    }

    var suffix: u32 = 2;
    var buf: [128]u8 = undefined;
    while (suffix < 100) : (suffix += 1) {
        const resolved = std.fmt.bufPrint(&buf, "{s}-{d}", .{ base_name, suffix }) catch |err| {
            core.logging.logError("ses", "failed to format suffixed session name", err);
            break;
        };
        if (!isSessionNameInUse(store, resolved, exclude_client_id, exclude_session_id)) {
            return try allocator.dupe(u8, resolved);
        }
    }

    var uuid_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);
    const hex = std.fmt.bytesToHex(&uuid_bytes, .lower);
    const fallback = std.fmt.bufPrint(&buf, "{s}-{s}", .{ base_name, hex }) catch |err| {
        core.logging.logError("ses", "failed to format random session name fallback", err);
        return error.NoSpaceLeft;
    };
    return try allocator.dupe(u8, fallback);
}
