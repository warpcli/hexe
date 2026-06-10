const std = @import("std");
const core = @import("core");
const session_model = core.session_model;

pub fn paneUuidInList(list: []const [32]u8, uuid: [32]u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, &candidate, &uuid)) return true;
    }
    return false;
}

pub fn firstLayoutPaneUuid(node: ?*const session_model.SessionLayoutNode) ?[32]u8 {
    const root = node orelse return null;
    return switch (root.*) {
        .pane => |uuid| uuid,
        .split => |split| firstLayoutPaneUuid(split.first) orelse firstLayoutPaneUuid(split.second),
    };
}

pub fn normalizeAfterPaneRemoval(snapshot: *session_model.SessionSnapshot) void {
    if (snapshot.tabs.items.len == 0) {
        snapshot.active_tab = 0;
        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (!snapshot.panes.contains(active_float_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        snapshot.focused_pane_uuid = snapshot.active_float_uuid;
        return;
    }

    if (snapshot.active_tab >= snapshot.tabs.items.len) {
        snapshot.active_tab = snapshot.tabs.items.len - 1;
    }

    if (snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid == null) {
        snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid =
            firstLayoutPaneUuid(snapshot.tabs.items[snapshot.active_tab].root);
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        if (!snapshot.panes.contains(active_float_uuid)) {
            snapshot.active_float_uuid = null;
        }
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        snapshot.focused_pane_uuid = active_float_uuid;
    } else {
        snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
    }
}

pub fn removePaneFromSessionSnapshot(
    allocator: std.mem.Allocator,
    snapshot: *session_model.SessionSnapshot,
    pane_uuid: [32]u8,
) void {
    const pane_state = snapshot.panes.get(pane_uuid) orelse {
        var float_idx: ?usize = null;
        for (snapshot.floats.items, 0..) |float_state, idx| {
            if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                float_idx = idx;
                break;
            }
        }
        if (float_idx) |idx| {
            _ = snapshot.floats.orderedRemove(idx);
        }
        if (snapshot.active_float_uuid) |active_float_uuid| {
            if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
                snapshot.active_float_uuid = null;
            }
        }
        if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
            if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                snapshot.focused_pane_uuid = null;
            }
        }
        normalizeAfterPaneRemoval(snapshot);
        return;
    };

    switch (pane_state.kind) {
        .float => {
            var float_idx: ?usize = null;
            for (snapshot.floats.items, 0..) |float_state, idx| {
                if (std.mem.eql(u8, &float_state.pane_uuid, &pane_uuid)) {
                    float_idx = idx;
                    break;
                }
            }
            if (float_idx) |idx| {
                _ = snapshot.floats.orderedRemove(idx);
            }
            _ = snapshot.panes.remove(pane_uuid);
        },
        .split => {
            var removed_tab_idx: ?usize = null;
            if (pane_state.parent_tab) |tab_idx| {
                if (tab_idx < snapshot.tabs.items.len) {
                    const removed_from_layout = session_model.removePaneFromLayout(snapshot.allocator, &snapshot.tabs.items[tab_idx].root, pane_uuid) catch |err| {
                        core.logging.logError("ses", "failed to remove split pane from session snapshot layout", err);
                        return;
                    };
                    if (!removed_from_layout) {
                        core.logging.warn("ses", "split pane {s} missing from parent layout during snapshot removal", .{pane_uuid[0..8]});
                    }
                    if (snapshot.tabs.items[tab_idx].focused_pane_uuid) |focused_pane_uuid| {
                        if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
                            snapshot.tabs.items[tab_idx].focused_pane_uuid =
                                firstLayoutPaneUuid(snapshot.tabs.items[tab_idx].root);
                        }
                    }
                    if (snapshot.tabs.items[tab_idx].root == null) {
                        var removed_tab = snapshot.tabs.orderedRemove(tab_idx);
                        removed_tab.deinit();
                        removed_tab_idx = tab_idx;
                    }
                }
            }

            _ = snapshot.panes.remove(pane_uuid);

            if (removed_tab_idx) |tab_idx| {
                var remove_split_uuids: std.ArrayList([32]u8) = .empty;
                defer remove_split_uuids.deinit(allocator);

                var pane_iter = snapshot.panes.iterator();
                while (pane_iter.next()) |entry| {
                    const parent = entry.value_ptr.parent_tab orelse continue;
                    switch (entry.value_ptr.kind) {
                        .split => {
                            if (parent == tab_idx) {
                                remove_split_uuids.append(allocator, entry.key_ptr.*) catch |err| {
                                    core.logging.logError("ses", "failed to collect split pane for tab removal", err);
                                };
                            } else if (parent > tab_idx) {
                                entry.value_ptr.parent_tab = parent - 1;
                            }
                        },
                        .float => {
                            if (parent == tab_idx) {
                                entry.value_ptr.parent_tab = null;
                            } else if (parent > tab_idx) {
                                entry.value_ptr.parent_tab = parent - 1;
                            }
                        },
                    }
                }
                for (remove_split_uuids.items) |split_uuid| {
                    _ = snapshot.panes.remove(split_uuid);
                }

                for (snapshot.floats.items) |*float_state| {
                    if (float_state.parent_tab) |parent| {
                        if (parent == tab_idx) {
                            float_state.parent_tab = null;
                        } else if (parent > tab_idx) {
                            float_state.parent_tab = parent - 1;
                        }
                    }
                }
            }
        },
    }

    if (snapshot.active_float_uuid) |active_float_uuid| {
        if (std.mem.eql(u8, &active_float_uuid, &pane_uuid)) {
            snapshot.active_float_uuid = null;
        }
    }
    if (snapshot.focused_pane_uuid) |focused_pane_uuid| {
        if (std.mem.eql(u8, &focused_pane_uuid, &pane_uuid)) {
            snapshot.focused_pane_uuid = null;
        }
    }

    normalizeAfterPaneRemoval(snapshot);
}
