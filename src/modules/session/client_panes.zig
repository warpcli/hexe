const std = @import("std");
const core = @import("core");
const snapshot_mod = @import("snapshot.zig");
const store_mod = @import("store.zig");

pub fn appendUniquePaneUuid(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([32]u8),
    uuid: [32]u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, &existing, &uuid)) return;
    }
    try list.append(allocator, uuid);
}

pub fn collectDetachPaneUuids(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    client: *const store_mod.Client,
    list: *std.ArrayList([32]u8),
) !void {
    for (client.pane_uuids.items) |uuid| {
        if (store.panes.get(uuid)) |pane| {
            if (pane.attached_to == null or pane.attached_to.? != client.id) continue;
            try appendUniquePaneUuid(allocator, list, uuid);
        }
    }

    const snapshot = client.session_snapshot orelse {
        core.logging.warn("ses", "collectDetachPaneUuids: client has no session snapshot; using direct pane list only", .{});
        return;
    };
    var pane_iter = snapshot.panes.keyIterator();
    while (pane_iter.next()) |uuid| {
        if (store.panes.get(uuid.*)) |pane| {
            if (pane.attached_to == null or pane.attached_to.? != client.id) continue;
            try appendUniquePaneUuid(allocator, list, uuid.*);
        }
    }
}

pub fn collectDetachPaneUuidsWithFallback(
    allocator: std.mem.Allocator,
    store: *store_mod.SessionStore,
    client: *const store_mod.Client,
    list: *std.ArrayList([32]u8),
    comptime log_context: []const u8,
) void {
    collectDetachPaneUuids(allocator, store, client, list) catch |err| {
        core.logging.logError("ses", log_context, err);
        for (client.pane_uuids.items) |uuid| {
            appendUniquePaneUuid(allocator, list, uuid) catch |append_err| {
                core.logging.logError("ses", log_context, append_err);
                continue;
            };
        }
    };
}

pub fn pruneSnapshotToPaneList(
    allocator: std.mem.Allocator,
    snapshot: *core.session_model.SessionSnapshot,
    pane_uuids: []const [32]u8,
) !void {
    var to_remove: std.ArrayList([32]u8) = .empty;
    defer to_remove.deinit(allocator);

    var pane_iter = snapshot.panes.keyIterator();
    while (pane_iter.next()) |uuid| {
        if (!snapshot_mod.paneUuidInList(pane_uuids, uuid.*)) {
            try to_remove.append(allocator, uuid.*);
        }
    }

    for (to_remove.items) |uuid| {
        snapshot_mod.removePaneFromSessionSnapshot(allocator, snapshot, uuid);
    }
}
