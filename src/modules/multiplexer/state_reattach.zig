const std = @import("std");
const core = @import("core");
const mux = @import("main.zig");
const session_model = core.session_model;

const state_types = @import("state_types.zig");
const Tab = state_types.Tab;

const layout_mod = @import("layout.zig");
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const ses_client = @import("ses_client.zig");
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;

const SessionSnapshot = session_model.SessionSnapshot;
const SessionLayoutNode = session_model.SessionLayoutNode;
const SessionFloat = session_model.SessionFloat;
const AdoptInfo = struct { pane_id: u16 };

/// Validate the structure of mux state JSON before attempting restoration.
/// This prevents crashes from malformed/corrupted JSON.
fn validateMuxStateJson(value: *const std.json.Value) bool {
    // Root must be an object
    if (value.* != .object) {
        mux.debugLog("validateMuxStateJson: root is not an object", .{});
        return false;
    }
    const root = value.object;

    // Required fields with type checks
    const required_fields = .{
        .{ "uuid", .string },
        .{ "session_name", .string },
        .{ "tab_counter", .integer },
        .{ "tabs", .array },
        .{ "floats", .array },
        .{ "active_tab", .integer },
    };

    inline for (required_fields) |field_spec| {
        const field_name = field_spec[0];
        const expected_type = field_spec[1];

        const field_value = root.get(field_name) orelse {
            mux.debugLog("validateMuxStateJson: missing required field '{s}'", .{field_name});
            return false;
        };

        const matches = switch (expected_type) {
            .string => field_value == .string,
            .integer => field_value == .integer,
            .array => field_value == .array,
            else => false,
        };

        if (!matches) {
            mux.debugLog("validateMuxStateJson: field '{s}' has wrong type", .{field_name});
            return false;
        }
    }

    // active_floating can be null or integer
    if (root.get("active_floating")) |af| {
        if (af != .null and af != .integer) {
            mux.debugLog("validateMuxStateJson: active_floating must be null or integer", .{});
            return false;
        }
    }

    // Validate tabs array elements
    const tabs = root.get("tabs").?.array;
    for (tabs.items) |tab_val| {
        if (tab_val != .object) {
            mux.debugLog("validateMuxStateJson: tabs array contains non-object", .{});
            return false;
        }
        const tab_obj = tab_val.object;

        // Each tab must have name, splits array
        if (tab_obj.get("name")) |name| {
            if (name != .string) {
                mux.debugLog("validateMuxStateJson: tab name is not a string", .{});
                return false;
            }
        } else {
            mux.debugLog("validateMuxStateJson: tab missing name", .{});
            return false;
        }

        if (tab_obj.get("splits")) |splits| {
            if (splits != .array) {
                mux.debugLog("validateMuxStateJson: tab splits is not an array", .{});
                return false;
            }
        }
    }

    // Validate floats array elements
    const floats = root.get("floats").?.array;
    for (floats.items) |float_val| {
        if (float_val != .object) {
            mux.debugLog("validateMuxStateJson: floats array contains non-object", .{});
            return false;
        }
    }

    mux.debugLog("validateMuxStateJson: validation passed", .{});
    return true;
}

fn applyDeferredPaneExits(self: anytype) void {
    var pending: std.ArrayList([32]u8) = .empty;
    defer pending.deinit(self.allocator);
    self.ses_client.drainPendingPaneExits(&pending);

    for (pending.items) |uuid| {
        var marked = false;

        for (self.tabs.items) |*tab| {
            var it = tab.layout.splits.valueIterator();
            while (it.next()) |pane_ptr| {
                if (std.mem.eql(u8, &pane_ptr.*.uuid, &uuid)) {
                    switch (pane_ptr.*.backend) {
                        .pod => |*pod| {
                            pod.dead = true;
                            marked = true;
                        },
                        else => {},
                    }
                }
            }
        }

        for (self.floats.items) |pane| {
            if (std.mem.eql(u8, &pane.uuid, &uuid)) {
                switch (pane.backend) {
                    .pod => |*pod| {
                        pod.dead = true;
                        marked = true;
                    },
                    else => {},
                }
            }
        }

        if (marked) {
            mux.debugLog("reattachSession: applied deferred pane_exited uuid={s}", .{uuid[0..8]});
        }
    }
}

fn normalizeRestoredSessionName(name: []const u8) []const u8 {
    if (name.len >= 3) {
        const last_char = name[name.len - 1];
        if (last_char >= '1' and last_char <= '9' and name[name.len - 2] == '-') {
            return name[0 .. name.len - 2];
        }
    }
    return name;
}

fn clearStateForRestore(self: anytype) void {
    while (self.tabs.items.len > 0) {
        const tab_opt = self.tabs.pop();
        if (tab_opt) |tab_const| {
            var tab = tab_const;
            tab.deinit();
        }
    }

    while (self.floats.items.len > 0) {
        const p_opt = self.floats.pop();
        if (p_opt) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
    }

    self.active_tab = 0;
    self.active_floating = null;
    self.tab_last_floating_uuid.clearRetainingCapacity();
    self.tab_last_focus_kind.clearRetainingCapacity();
}

fn hydratePaneMetadata(self: anytype, pane: *Pane, uuid: [32]u8) void {
    if (self.ses_client.getPaneInfoSnapshot(uuid)) |snap| {
        defer if (snap.fg_name) |s| self.allocator.free(s);
        if (snap.name) |name| {
            if (self.pane_names.get(uuid)) |old_name| self.allocator.free(old_name);
            self.pane_names.put(uuid, name) catch self.allocator.free(name);
        }
        pane.setSesCwd(snap.cwd);
        self.setPaneProc(uuid, snap.fg_name, snap.fg_pid);
    } else {
        self.ses_client.requestPaneProcess(uuid);
        self.ses_client.requestPaneCwd(uuid);
    }
}

fn ensureAdoptInfo(
    self: anytype,
    uuid: [32]u8,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
) ?AdoptInfo {
    if (uuid_pane_map.get(uuid)) |info| return info;
    if (self.ses_client.adoptPane(uuid)) |adopt_res| {
        const info = AdoptInfo{ .pane_id = adopt_res.pane_id };
        uuid_pane_map.put(uuid, info) catch {};
        return info;
    } else |_| {
        return null;
    }
}

fn ensureSplitPaneView(
    self: anytype,
    tab: *Tab,
    pane_uuid: [32]u8,
    local_ids: *std.AutoHashMap([32]u8, u16),
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    used_uuids: *std.AutoHashMap([32]u8, void),
    remembered_focus_uuid: ?[32]u8,
    actual_focus_uuid: ?[32]u8,
) ?u16 {
    if (local_ids.get(pane_uuid)) |existing| return existing;
    if (used_uuids.contains(pane_uuid)) return null;

    const info = ensureAdoptInfo(self, pane_uuid, uuid_pane_map) orelse return null;
    const vt_fd = self.ses_client.getVtFd() orelse return null;

    const pane_id = tab.layout.next_split_id;
    tab.layout.next_split_id +%= 1;
    if (tab.layout.next_split_id == 0) tab.layout.next_split_id = 1;

    const pane = self.allocator.create(Pane) catch return null;
    errdefer self.allocator.destroy(pane);

    pane.initWithPod(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, pane_uuid) catch return null;
    pane.focused = if (actual_focus_uuid) |focused_uuid| std.mem.eql(u8, &focused_uuid, &pane_uuid) else false;
    pane.configureNotificationsFromPop(&self.pop_config.pane.notification);
    hydratePaneMetadata(self, pane, pane_uuid);

    tab.layout.splits.put(pane_id, pane) catch {
        pane.deinit();
        self.allocator.destroy(pane);
        return null;
    };
    local_ids.put(pane_uuid, pane_id) catch {};
    used_uuids.put(pane_uuid, {}) catch {};

    if (remembered_focus_uuid) |focus_uuid| {
        if (std.mem.eql(u8, &focus_uuid, &pane_uuid)) {
            tab.layout.focused_split_id = pane_id;
        }
    }

    return pane_id;
}

fn freeRestoredLayoutNode(allocator: std.mem.Allocator, node: *LayoutNode) void {
    switch (node.*) {
        .pane => {},
        .split => |split| {
            freeRestoredLayoutNode(allocator, split.first);
            freeRestoredLayoutNode(allocator, split.second);
        },
    }
    allocator.destroy(node);
}

fn restoreLayoutNode(
    self: anytype,
    tab: *Tab,
    node: *const SessionLayoutNode,
    local_ids: *std.AutoHashMap([32]u8, u16),
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    used_uuids: *std.AutoHashMap([32]u8, void),
    remembered_focus_uuid: ?[32]u8,
    actual_focus_uuid: ?[32]u8,
) ?*LayoutNode {
    switch (node.*) {
        .pane => |pane_uuid| {
            const pane_id = ensureSplitPaneView(
                self,
                tab,
                pane_uuid,
                local_ids,
                uuid_pane_map,
                used_uuids,
                remembered_focus_uuid,
                actual_focus_uuid,
            ) orelse return null;
            const restored = self.allocator.create(LayoutNode) catch return null;
            restored.* = .{ .pane = pane_id };
            return restored;
        },
        .split => |split| {
            const first = restoreLayoutNode(self, tab, split.first, local_ids, uuid_pane_map, used_uuids, remembered_focus_uuid, actual_focus_uuid);
            const second = restoreLayoutNode(self, tab, split.second, local_ids, uuid_pane_map, used_uuids, remembered_focus_uuid, actual_focus_uuid);

            if (first == null and second == null) return null;
            if (first == null) return second;
            if (second == null) return first;

            const restored = self.allocator.create(LayoutNode) catch {
                if (first) |f| {
                    freeRestoredLayoutNode(self.allocator, f);
                }
                if (second) |s| {
                    freeRestoredLayoutNode(self.allocator, s);
                }
                return null;
            };
            restored.* = .{
                .split = .{
                    .dir = if (split.dir == .horizontal) .horizontal else .vertical,
                    .ratio = split.ratio,
                    .first = first.?,
                    .second = second.?,
                },
            };
            return restored;
        },
    }
}

fn restoreFloatPane(
    self: anytype,
    float_state: SessionFloat,
    uuid_pane_map: *std.AutoHashMap([32]u8, AdoptInfo),
    used_uuids: *std.AutoHashMap([32]u8, void),
    actual_focus_uuid: ?[32]u8,
) ?*Pane {
    if (used_uuids.contains(float_state.pane_uuid)) return null;
    const info = ensureAdoptInfo(self, float_state.pane_uuid, uuid_pane_map) orelse return null;
    const vt_fd = self.ses_client.getVtFd() orelse return null;

    const pane = self.allocator.create(Pane) catch return null;
    errdefer self.allocator.destroy(pane);

    const local_id: u16 = @intCast(100 + self.floats.items.len);
    pane.initWithPod(self.allocator, local_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, float_state.pane_uuid) catch return null;
    hydratePaneMetadata(self, pane, float_state.pane_uuid);

    pane.floating = true;
    pane.focused = if (actual_focus_uuid) |focused_uuid| std.mem.eql(u8, &focused_uuid, &float_state.pane_uuid) else false;
    pane.visible = float_state.visible;
    pane.tab_visible = float_state.tab_visible;
    pane.float_key = float_state.float_key;
    pane.float_width_pct = float_state.width_pct;
    pane.float_height_pct = float_state.height_pct;
    pane.float_pos_x_pct = float_state.pos_x_pct;
    pane.float_pos_y_pct = float_state.pos_y_pct;
    pane.float_pad_x = float_state.pad_x;
    pane.float_pad_y = float_state.pad_y;
    pane.is_pwd = float_state.is_pwd;
    pane.sticky = float_state.sticky;
    pane.parent_tab = float_state.parent_tab;
    pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

    if (pane.float_key != 0) {
        if (self.getLayoutFloatByKey(pane.float_key)) |float_def| {
            const style = if (float_def.style) |*s| s else if (self.config.float_style_default) |*s| s else null;
            if (style) |s| pane.float_style = s;
            pane.border_color = float_def.color orelse self.config.float_color;
        }
    }

    if (self.ses_client.isConnected()) {
        if (self.ses_client.getPaneName(float_state.pane_uuid)) |name| {
            pane.float_title = name;
        }
    }

    used_uuids.put(float_state.pane_uuid, {}) catch {};
    return pane;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    mux.debugLog("reattachSession: starting with prefix={s}", .{session_id_prefix});

    // Set flag to prevent SIGHUP from interrupting reattach
    self.reattach_in_progress.store(true, .release);
    defer self.reattach_in_progress.store(false, .release);

    // Track reattach start time for timeout detection
    const reattach_start = std.time.milliTimestamp();

    if (!self.ses_client.isConnected()) {
        mux.debugLog("reattachSession: ses_client not connected, aborting", .{});
        return false;
    }

    // Try to reattach session (server supports prefix matching).
    mux.debugLog("reattachSession: calling ses_client.reattachSession", .{});
    const result = self.ses_client.reattachSession(session_id_prefix) catch |e| {
        mux.debugLog("reattachSession: ses_client.reattachSession failed: {s}", .{@errorName(e)});
        return false;
    };
    if (result == null) {
        mux.debugLog("reattachSession: ses_client.reattachSession returned null (session not found)", .{});
        return false;
    }

    const reattach_result = result.?;
    mux.debugLog("reattachSession: got result with {d} panes, state_json_len={d}", .{ reattach_result.pane_uuids.len, reattach_result.session_state_json.len });
    defer {
        self.allocator.free(reattach_result.session_state_json);
        self.allocator.free(reattach_result.pane_uuids);
    }

    var snapshot = SessionSnapshot.fromJson(self.allocator, reattach_result.session_state_json) catch |e| {
        mux.debugLog("reattachSession: snapshot parse failed: {s}", .{@errorName(e)});
        return false;
    };
    defer snapshot.deinit();

    // Check timeout after JSON parsing
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after JSON parse ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: JSON parsing took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed)",
                .{@divTrunc(elapsed, 1000)},
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after JSON parse ({d}ms)", .{elapsed});
        }
    }

    clearStateForRestore(self);
    self.uuid = snapshot.uuid;

    const restored_name = normalizeRestoredSessionName(snapshot.session_name);
    if (self.session_name_owned) |old| self.allocator.free(old);
    const duped_name = self.allocator.dupe(u8, restored_name) catch return false;
    self.session_name = duped_name;
    self.session_name_owned = duped_name;

    self.tab_counter = if (snapshot.tab_counter > 1000) 0 else snapshot.tab_counter;
    const wanted_active_tab = snapshot.active_tab;

    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    mux.debugLog("reattachSession: adopting {d} panes", .{reattach_result.pane_uuids.len});
    var failed_adoptions: usize = 0;
    const total_panes = reattach_result.pane_uuids.len;

    for (reattach_result.pane_uuids, 0..) |uuid, i| {
        mux.debugLog("reattachSession: adopting pane {d}/{d} uuid={s}", .{ i + 1, total_panes, uuid[0..8] });

        // Check for duplicate UUID in the list
        if (uuid_pane_map.contains(uuid)) {
            mux.debugLog("reattachSession: DUPLICATE UUID detected: {s}, skipping", .{uuid[0..8]});
            failed_adoptions += 1;
            continue;
        }

        const adopt_result = self.ses_client.adoptPane(uuid) catch |e| {
            mux.debugLog("reattachSession: adoptPane failed for uuid={s}: {s}", .{ uuid[0..8], @errorName(e) });
            failed_adoptions += 1;
            continue;
        };
        mux.debugLogUuid(&uuid, "reattachSession: adoptPane ok pane_id={d} vt_fd={?d}", .{ adopt_result.pane_id, self.ses_client.vt_fd });
        uuid_pane_map.put(uuid, .{ .pane_id = adopt_result.pane_id }) catch {};
    }
    mux.debugLog("reattachSession: adopted {d} panes into uuid_pane_map", .{uuid_pane_map.count()});

    // Notify user if some panes failed to reattach
    if (failed_adoptions > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d}/{d} panes failed to reattach",
            .{ failed_adoptions, total_panes },
        ) catch "Warning: Some panes failed to reattach";
        defer if (!std.mem.eql(u8, msg, "Warning: Some panes failed to reattach")) self.allocator.free(msg);
        self.notifications.showFor(msg, 5000);
        mux.debugLog("reattachSession: notified user about {d} failed adoptions", .{failed_adoptions});
    }

    // Check timeout after pane adoption
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after pane adoption ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: pane adoption took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed, {d} panes adopted)",
                .{ @divTrunc(elapsed, 1000), uuid_pane_map.count() },
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after adoption ({d}ms)", .{elapsed});
        }
    }

    for (snapshot.tabs.items) |snapshot_tab| {
        const name_owned = self.allocator.dupe(u8, snapshot_tab.name) catch continue;
        var tab = Tab.initOwned(self.allocator, self.layout_width, self.layout_height, name_owned, self.pop_config.carrier.notification);
        tab.uuid = snapshot_tab.uuid;

        if (self.ses_client.isConnected()) {
            tab.layout.setSesClient(&self.ses_client);
        }
        tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

        var local_ids = std.AutoHashMap([32]u8, u16).init(self.allocator);
        defer local_ids.deinit();

        if (snapshot_tab.root) |root| {
            tab.layout.root = restoreLayoutNode(
                self,
                &tab,
                root,
                &local_ids,
                &uuid_pane_map,
                &used_uuids,
                snapshot_tab.focused_pane_uuid,
                snapshot.focused_pane_uuid,
            );
        }

        if (!tab.layout.splits.contains(tab.layout.focused_split_id)) {
            var split_it = tab.layout.splits.iterator();
            if (split_it.next()) |entry| {
                tab.layout.focused_split_id = entry.key_ptr.*;
            }
        }

        if (tab.layout.root == null and tab.layout.splits.count() > 0) {
            const node = self.allocator.create(LayoutNode) catch {
                tab.deinit();
                continue;
            };
            node.* = .{ .pane = tab.layout.focused_split_id };
            tab.layout.root = node;
        }

        self.tabs.append(self.allocator, tab) catch {
            tab.deinit();
            continue;
        };
    }

    self.tab_last_floating_uuid.clearRetainingCapacity();
    for (0..self.tabs.items.len) |_| {
        self.tab_last_floating_uuid.append(self.allocator, null) catch return false;
    }

    self.tab_last_focus_kind.clearRetainingCapacity();
    for (0..self.tabs.items.len) |_| {
        self.tab_last_focus_kind.append(self.allocator, .split) catch return false;
    }

    for (snapshot.floats.items) |float_state| {
        const pane = restoreFloatPane(self, float_state, &uuid_pane_map, &used_uuids, snapshot.focused_pane_uuid) orelse continue;
        self.floats.append(self.allocator, pane) catch {
            pane.deinit();
            self.allocator.destroy(pane);
            continue;
        };
    }

    // Prune dead pane nodes from layout trees. Pods that died during detach
    // (e.g., from SIGPIPE) leave orphan nodes in the tree that would corrupt
    // the layout by allocating space for non-existent panes.
    for (self.tabs.items) |*tab| {
        tab.layout.pruneDeadNodes();
    }

    // Remove tabs that have no live panes (all pods died).
    {
        var i: usize = 0;
        var removed_tabs: usize = 0;
        while (i < self.tabs.items.len) {
            if (self.tabs.items[i].layout.splits.count() == 0) {
                // Don't remove the LAST tab - keep at least one tab always.
                if (self.tabs.items.len > 1) {
                    const tab_name = self.tabs.items[i].name;
                    mux.debugLog("reattachSession: removing empty tab: {s}", .{tab_name});
                    var dead_tab = self.tabs.orderedRemove(i);
                    dead_tab.deinit();
                    removed_tabs += 1;
                    // Don't increment i, next tab shifted into this position
                } else {
                    mux.debugLog("reattachSession: keeping last empty tab to prevent zero tabs", .{});
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        // Notify user if tabs were removed
        if (removed_tabs > 0) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: {d} empty tab(s) removed (all panes died)",
                .{removed_tabs},
            ) catch "Warning: Empty tabs were removed";
            defer if (!std.mem.eql(u8, msg, "Warning: Empty tabs were removed")) self.allocator.free(msg);
            self.notifications.showFor(msg, 4000);
            mux.debugLog("reattachSession: removed {d} empty tabs", .{removed_tabs});
        }
    }

    // Safety check: ensure we have at least one tab.
    // If all tabs were empty and removed, create a new one.
    if (self.tabs.items.len == 0) {
        mux.debugLog("reattachSession: CRITICAL - all tabs removed, creating new tab", .{});
        self.createTab() catch {
            mux.debugLog("reattachSession: FAILED to create recovery tab", .{});
            return false;
        };
        self.notifications.showFor("Warning: All tabs were empty, created new tab", 5000);
    }

    // Recalculate all layouts for current terminal size.
    for (self.tabs.items) |*tab| {
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    // Validate and fix parent_tab indices for floating panes
    var invalid_parent_tabs: usize = 0;
    for (self.floats.items) |fp| {
        if (fp.parent_tab) |parent_idx| {
            if (parent_idx >= self.tabs.items.len) {
                mux.debugLog("reattachSession: invalid parent_tab {d} (only {d} tabs), setting to null", .{ parent_idx, self.tabs.items.len });
                fp.parent_tab = null;
                invalid_parent_tabs += 1;
            }
        }
    }
    // Notify user if any parent_tab links were broken
    if (invalid_parent_tabs > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d} float(s) had invalid parent tab, reset to global",
            .{invalid_parent_tabs},
        ) catch "Warning: Some floats had invalid parent tab references";
        defer if (!std.mem.eql(u8, msg, "Warning: Some floats had invalid parent tab references")) self.allocator.free(msg);
        self.notifications.showFor(msg, 4000);
        mux.debugLog("reattachSession: corrected {d} invalid parent_tab references", .{invalid_parent_tabs});
    }

    // Recalculate floating pane positions.
    self.resizeFloatingPanes();

    // Apply restored active indices now that all state is present.
    if (self.tabs.items.len > 0) {
        self.active_tab = @min(wanted_active_tab, self.tabs.items.len - 1);
    } else {
        self.active_tab = 0;
    }
    self.active_floating = null;
    if (snapshot.active_float_uuid) |active_float_uuid| {
        for (self.floats.items, 0..) |pane, idx| {
            if (std.mem.eql(u8, &pane.uuid, &active_float_uuid)) {
                self.active_floating = idx;
                break;
            }
        }
    }
    if (self.active_floating) |idx| {
        if (self.active_tab < self.tab_last_floating_uuid.items.len) {
            self.tab_last_floating_uuid.items[self.active_tab] = self.floats.items[idx].uuid;
        }
        if (self.active_tab < self.tab_last_focus_kind.items.len) {
            self.tab_last_focus_kind.items[self.active_tab] = .float;
        }
    }

    self.renderer.invalidate();
    self.force_full_render = true;

    mux.debugLog("reattachSession: tabs restored={d}, floats restored={d}", .{ self.tabs.items.len, self.floats.items.len });

    // Check timeout after layout restoration
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after layout restore ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: layout restoration took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s total, {d} tabs restored)",
                .{ @divTrunc(elapsed, 1000), self.tabs.items.len },
            ) catch "Warning: reattach taking longer than expected";
            defer if (!std.mem.eql(u8, msg, "Warning: reattach taking longer than expected")) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after layout restore ({d}ms)", .{elapsed});
        }
    }

    if (self.tabs.items.len == 0) {
        mux.debugLog("reattachSession: no tabs restored, returning false", .{});
        return false;
    }

    // Re-register with restored UUID/name before requesting backlog replay.
    // This releases the attach session lock and stabilizes client identity first.
    mux.debugLog("reattachSession: calling updateSession uuid={s} name={s}", .{ self.uuid[0..8], self.session_name });
    self.ses_client.updateSession(self.uuid, self.session_name) catch |e| {
        core.logging.logError("mux", "updateSession failed in restoreLayout", e);
        mux.debugLog("reattachSession: updateSession FAILED: {s}", .{@errorName(e)});
    };

    // Signal SES that we're ready for backlog replay.
    // This triggers deferred VT reconnection to PODs, which replays their buffers.
    mux.debugLog("reattachSession: calling requestBacklogReplay", .{});
    self.ses_client.requestBacklogReplay() catch |e| {
        mux.debugLog("reattachSession: requestBacklogReplay FAILED: {s}", .{@errorName(e)});
    };
    mux.debugLog("reattachSession: requestBacklogReplay done", .{});

    // Sync-phase reads can consume async pane_exited messages before the IPC
    // loop starts. Apply those exits now so dead panes/floats are not kept
    // around in a frozen state.
    applyDeferredPaneExits(self);

    // Final timeout check after backlog replay
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        mux.debugLog("reattachSession: total elapsed time: {d}ms", .{elapsed});
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after backlog replay ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: session restored but backlog replay incomplete", 5000);
            // Don't return false here - the session is already restored, just warn user
        }
    }

    mux.debugLog("reattachSession: returning true, tabs={d} floats={d}", .{ self.tabs.items.len, self.floats.items.len });
    return true;
}

fn intFieldCast(comptime T: type, obj: std.json.ObjectMap, key: []const u8) ?T {
    const value = obj.get(key) orelse return null;
    if (value != .integer) return null;
    if (value.integer < 0) return null;
    return std.math.cast(T, value.integer);
}

/// Attach to orphaned pane by UUID prefix (for --attach CLI).
pub fn attachOrphanedPane(self: anytype, uuid_prefix: []const u8) bool {
    if (!self.ses_client.isConnected()) return false;

    // Get list of orphaned panes and find matching UUID.
    var tabs: [32]OrphanedPaneInfo = undefined;
    const count = self.ses_client.listOrphanedPanes(&tabs) catch return false;

    for (tabs[0..count]) |p| {
        if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
            // Found matching pane, adopt it.
            const result = self.ses_client.adoptPane(p.uuid) catch return false;

            // Create a new tab with this pane.
            var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, "attached", self.pop_config.carrier.notification);
            var tab_needs_cleanup = true;
            defer if (tab_needs_cleanup) tab.deinit();

            if (self.ses_client.isConnected()) {
                tab.layout.setSesClient(&self.ses_client);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

            const vt_fd = self.ses_client.getVtFd() orelse return false;

            const pane = self.allocator.create(Pane) catch return false;
            var pane_needs_cleanup = true;
            defer if (pane_needs_cleanup) self.allocator.destroy(pane);

            pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.pane_id, vt_fd, result.uuid) catch {
                return false;
            };

            if (self.ses_client.getPaneInfoSnapshot(result.uuid)) |snap| {
                defer if (snap.fg_name) |s| self.allocator.free(s);
                if (snap.name) |name| {
                    if (self.pane_names.get(result.uuid)) |old_name| self.allocator.free(old_name);
                    self.pane_names.put(result.uuid, name) catch self.allocator.free(name);
                }
                pane.setSesCwd(snap.cwd);
                self.setPaneProc(result.uuid, snap.fg_name, snap.fg_pid);
            } else {
                self.ses_client.requestPaneProcess(result.uuid);
                self.ses_client.requestPaneCwd(result.uuid);
            }

            pane.focused = true;
            pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

            // Add pane to layout manually.
            tab.layout.splits.put(0, pane) catch {
                pane.deinit();
                return false;
            };
            // Pane is now owned by tab, no longer needs separate cleanup
            pane_needs_cleanup = false;

            const node = self.allocator.create(LayoutNode) catch return false;
            node.* = .{ .pane = 0 };
            tab.layout.root = node;
            tab.layout.next_split_id = 1;

            self.tabs.append(self.allocator, tab) catch return false;
            // Tab is now owned by tabs array, no longer needs cleanup
            tab_needs_cleanup = false;
            self.active_tab = self.tabs.items.len - 1;
            self.renderer.invalidate();
            self.force_full_render = true;
            return true;
        }
    }
    return false;
}
