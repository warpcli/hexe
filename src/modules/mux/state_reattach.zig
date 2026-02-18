const std = @import("std");
const core = @import("core");
const mux = @import("main.zig");

const state_types = @import("state_types.zig");
const Tab = state_types.Tab;

const layout_mod = @import("layout.zig");
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const ses_client = @import("ses_client.zig");
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;

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
    mux.debugLog("reattachSession: got result with {d} panes, state_json_len={d}", .{ reattach_result.pane_uuids.len, reattach_result.mux_state_json.len });
    defer {
        self.allocator.free(reattach_result.mux_state_json);
        self.allocator.free(reattach_result.pane_uuids);
    }

    // Parse the mux state JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reattach_result.mux_state_json, .{}) catch |e| {
        mux.debugLog("reattachSession: JSON parse failed: {s}", .{@errorName(e)});
        return false;
    };
    defer parsed.deinit();

    // Validate JSON schema before attempting to use it
    if (!validateMuxStateJson(&parsed.value)) {
        mux.debugLog("reattachSession: JSON schema validation failed", .{});
        return false;
    }

    // Validate serialization version and checksum for integrity
    if (parsed.value.object.get("version")) |ver_val| {
        if (ver_val == .integer and ver_val.integer >= 0) {
            const version: u32 = @intCast(ver_val.integer);
            if (version > 1) {
                mux.debugLog("reattachSession: unsupported version {d}, current is 1", .{version});
                self.notifications.showFor("Warning: Session data from newer version, may be incompatible", 5000);
            }
        }
    }

    // Verify checksum if present
    if (parsed.value.object.get("_checksum")) |checksum_val| {
        if (checksum_val == .integer and checksum_val.integer >= 0) {
            const stored_checksum: u64 = @intCast(checksum_val.integer);
            // Recalculate checksum on content before the checksum field
            // Find where ",\"_checksum\":" starts in the JSON
            const json_str = reattach_result.mux_state_json;
            if (std.mem.lastIndexOf(u8, json_str, ",\"_checksum\":")) |checksum_pos| {
                const content_only = json_str[0..checksum_pos];
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(content_only);
                hasher.update("}"); // Add the closing brace that was part of original
                const calculated_checksum = hasher.final();

                if (calculated_checksum != stored_checksum) {
                    mux.debugLog("reattachSession: checksum mismatch! stored={d} calculated={d}", .{ stored_checksum, calculated_checksum });
                    self.notifications.showFor("Warning: Session data integrity check failed (corrupted?)", 5000);
                    // Continue anyway but user is warned
                }
            }
        }
    }

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

    const root = parsed.value.object;

    // Clear current UI state before restoring.
    //
    // If we leave the previous session's tabs/panes around and then append the
    // restored tabs, focus and routing can point at panes that were never
    // adopted (blank/frozen) or double-adopted.
    // This is especially important for `hexe mux attach` because the mux starts
    // by creating a fresh tab, then reattaches.
    {
        // Deinit existing tab state.
        while (self.tabs.items.len > 0) {
            const tab_opt = self.tabs.pop();
            if (tab_opt) |tab_const| {
                var tab = tab_const;
                tab.deinit();
            }
        }

        // Deinit any existing floats.
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

        // Clear per-pane metadata caches from previous session state.
        {
            var shell_it = self.pane_shell.iterator();
            while (shell_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_shell.clearRetainingCapacity();

            var proc_it = self.pane_proc.iterator();
            while (proc_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_proc.clearRetainingCapacity();

            var name_it = self.pane_names.iterator();
            while (name_it.next()) |entry| {
                self.allocator.free(entry.value_ptr.*);
            }
            self.pane_names.clearRetainingCapacity();

            var req_it = self.pending_float_requests.iterator();
            while (req_it.next()) |entry| {
                if (entry.value_ptr.result_path) |path| {
                    self.allocator.free(path);
                }
            }
            self.pending_float_requests.clearRetainingCapacity();
        }
    }

    // Restore mux UUID (persistent identity).
    if (root.get("uuid")) |uuid_val| {
        const uuid_str = uuid_val.string;
        if (uuid_str.len == 32) {
            @memcpy(&self.uuid, uuid_str[0..32]);
        }
    }

    // Restore session name (must dupe since parsed JSON will be freed).
    if (root.get("session_name")) |name_val| {
        var restored_name = name_val.string;

        // VALIDATION: Detect and fix corrupted session_name.
        // Session names should be Greek letters (alpha, beta, ...) optionally with
        // collision suffix "-2", "-3", etc. They should NEVER be tab names like "alpha-1".
        // Tab names have format "session-N" where N starts at 1.
        //
        // If the restored name looks like a tab name (ends with "-1", "-2", etc.),
        // strip the suffix to recover the actual session name.
        //
        // Heuristic: If name ends with "-N" where N is a single digit >= 1,
        // it's likely a corrupted tab name. Strip the suffix.
        if (restored_name.len >= 3) {
            const last_char = restored_name[restored_name.len - 1];
            if (last_char >= '1' and last_char <= '9') {
                // Check if there's a dash before the digit.
                if (restored_name[restored_name.len - 2] == '-') {
                    // This looks like "alpha-1" format (tab name).
                    // Strip the "-N" suffix to recover session name.
                    restored_name = restored_name[0 .. restored_name.len - 2];
                    mux.debugLog("VALIDATION: stripped corrupted tab-format suffix from session_name, recovered: {s}", .{restored_name});
                    mux.debugLog("reattachSession: session_name recovered from tab-format corruption: {s}", .{restored_name});
                }
            }
        }

        // Free previous owned name if any.
        if (self.session_name_owned) |old| {
            self.allocator.free(old);
        }
        // Dupe the validated name from JSON.
        const duped = self.allocator.dupe(u8, restored_name) catch return false;
        self.session_name = duped;
        self.session_name_owned = duped;
    }

    // Restore tab counter (for session-N tab naming).
    if (root.get("tab_counter")) |tc_val| {
        if (tc_val == .integer and tc_val.integer >= 0) {
            const restored_counter: usize = @intCast(tc_val.integer);
            // Validate tab_counter is reasonable (not absurdly large).
            // A counter > 1000 suggests corruption or overflow.
            if (restored_counter > 1000) {
                mux.debugLog("VALIDATION: tab_counter suspiciously large ({d}), resetting to 0", .{restored_counter});
                self.tab_counter = 0;
            } else {
                self.tab_counter = restored_counter;
            }
        } else {
            mux.debugLog("VALIDATION: tab_counter is not an integer type, defaulting to 0", .{});
            self.tab_counter = 0;
        }
    }

    // Remember active tab/floating from the stored state.
    // We apply these after restoring tabs/floats so indices are valid.
    const wanted_active_tab: usize = if (root.get("active_tab")) |at| blk: {
        if (at != .integer or at.integer < 0) {
            mux.debugLog("reattachSession: active_tab is not an integer, defaulting to 0", .{});
            break :blk 0;
        }
        break :blk @intCast(at.integer);
    } else 0;
    const wanted_active_floating: ?usize = if (root.get("active_floating")) |af| blk: {
        if (af == .null) break :blk null;
        if (af != .integer or af.integer < 0) {
            mux.debugLog("reattachSession: active_floating is not an integer, defaulting to null", .{});
            break :blk null;
        }
        break :blk @intCast(af.integer);
    } else null;

    // Build a map of UUID -> pane_id for adopted panes.
    const AdoptInfo = struct { pane_id: u16 };
    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    // Track which UUIDs have been used during restoration to detect duplicates in JSON.
    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    mux.debugLog("reattachSession: adopting {d} panes", .{reattach_result.pane_uuids.len});
    // Track adoption failures for user notification
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
        mux.debugLog("reattachSession: adoptPane success, pane_id={d}", .{adopt_result.pane_id});
        uuid_pane_map.put(uuid, .{ .pane_id = adopt_result.pane_id }) catch {
            failed_adoptions += 1;
            continue;
        };
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

    // Restore tabs.
    if (root.get("tabs")) |tabs_arr| {
        for (tabs_arr.array.items) |tab_val| {
            const tab_obj = tab_val.object;
            const name_json = switch (tab_obj.get("name") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const focused_split_id = intFieldCast(u16, tab_obj, "focused_split_id") orelse continue;
            const next_split_id = intFieldCast(u16, tab_obj, "next_split_id") orelse continue;

            // Dupe the name since parsed JSON will be freed.
            const name_owned = self.allocator.dupe(u8, name_json) catch continue;
            var tab = Tab.initOwned(self.allocator, self.layout_width, self.layout_height, name_owned, self.pop_config.carrier.notification);

            // Restore tab UUID if present.
            if (tab_obj.get("uuid")) |uuid_val| {
                const uuid_str = uuid_val.string;
                if (uuid_str.len == 32) {
                    @memcpy(&tab.uuid, uuid_str[0..32]);
                }
            }

            if (self.ses_client.isConnected()) {
                tab.layout.setSesClient(&self.ses_client);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);
            tab.layout.focused_split_id = focused_split_id;
            tab.layout.next_split_id = next_split_id;

            // Restore splits.
            var restored_split_count: usize = 0;
            if (tab_obj.get("splits")) |splits_arr| {
                for (splits_arr.array.items) |pane_val| {
                    const pane_obj = pane_val.object;
                    const pane_id = intFieldCast(u16, pane_obj, "id") orelse continue;
                    const uuid_str = switch (pane_obj.get("uuid") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (uuid_str.len != 32) continue;

                    // Convert to [32]u8 for lookup.
                    var uuid_arr: [32]u8 = undefined;
                    @memcpy(&uuid_arr, uuid_str[0..32]);

                    // Check for duplicate UUID - if already used, skip this pane.
                    if (used_uuids.contains(uuid_arr)) {
                        mux.debugLog("reattachSession: duplicate UUID in splits: {s}, skipping", .{uuid_arr[0..8]});
                        continue;
                    }

                    // Try adopting from pre-collected pane_uuids first,
                    // then try adopting directly from SES by UUID.
                    var adopt_info: ?AdoptInfo = uuid_pane_map.get(uuid_arr);
                    if (adopt_info == null) {
                        // pane_uuids was empty - try adopting directly from SES.
                        if (self.ses_client.adoptPane(uuid_arr)) |adopt_res| {
                            adopt_info = .{ .pane_id = adopt_res.pane_id };
                        } else |_| {}
                    }

                    const info = adopt_info orelse continue;

                    // Mark this UUID as used.
                    used_uuids.put(uuid_arr, {}) catch {};
                    const pane = self.allocator.create(Pane) catch continue;
                    const vt_fd = self.ses_client.getVtFd() orelse {
                        self.allocator.destroy(pane);
                        continue;
                    };

                    pane.initWithPod(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, uuid_arr) catch {
                        self.allocator.destroy(pane);
                        continue;
                    };

                    if (self.ses_client.getPaneInfoSnapshot(uuid_arr)) |snap| {
                        defer if (snap.fg_name) |s| self.allocator.free(s);
                        if (snap.name) |name| {
                            if (self.pane_names.get(uuid_arr)) |old_name| self.allocator.free(old_name);
                            self.pane_names.put(uuid_arr, name) catch self.allocator.free(name);
                        }
                        pane.setSesCwd(snap.cwd);
                        self.setPaneProc(uuid_arr, snap.fg_name, snap.fg_pid);
                    } else {
                        self.ses_client.requestPaneProcess(uuid_arr);
                        self.ses_client.requestPaneCwd(uuid_arr);
                    }

                    // Restore pane properties.
                    pane.focused = if (pane_obj.get("focused")) |f| (f == .bool and f.bool) else false;

                    tab.layout.splits.put(pane_id, pane) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        continue;
                    };
                    restored_split_count += 1;
                }
            }

            // Skip empty tabs that restored no panes.
            if (restored_split_count == 0) {
                tab.deinit();
                continue;
            }

            // Restore layout tree.
            if (tab_obj.get("tree")) |tree_val| {
                if (tree_val != .null) {
                    tab.layout.root = self.deserializeLayoutNode(tree_val.object) catch null;
                }
            }

            // Remove tree nodes that reference panes we failed to restore.
            tab.layout.pruneDeadNodes();

            // Skip tabs that became empty after pruning dead nodes.
            if (tab.layout.splits.count() == 0) {
                tab.deinit();
                continue;
            }

            // Ensure focused split points to an existing pane.
            if (!tab.layout.splits.contains(tab.layout.focused_split_id)) {
                var split_it = tab.layout.splits.iterator();
                if (split_it.next()) |entry| {
                    tab.layout.focused_split_id = entry.key_ptr.*;
                }
            }

            if (tab.layout.getFocusedPane()) |focused| {
                focused.focused = true;
            }

            // Ensure there is a root node for rendering if tree restore failed.
            if (tab.layout.root == null) {
                const node = self.allocator.create(LayoutNode) catch {
                    tab.deinit();
                    continue;
                };
                node.* = .{ .pane = tab.layout.focused_split_id };
                tab.layout.root = node;
            }

            self.tabs.append(self.allocator, tab) catch {
                // Clean up tab and all its panes on append failure
                tab.deinit();
                continue;
            };
        }
    }

    // Reset per-tab float focus tracking to match restored tabs.
    self.tab_last_floating_uuid.clearRetainingCapacity();
    for (0..self.tabs.items.len) |_| {
        self.tab_last_floating_uuid.append(self.allocator, null) catch return false;
    }

    self.tab_last_focus_kind.clearRetainingCapacity();
    for (0..self.tabs.items.len) |_| {
        self.tab_last_focus_kind.append(self.allocator, .split) catch return false;
    }

    // Restore floats.
    if (root.get("floats")) |floats_arr| {
        for (floats_arr.array.items) |pane_val| {
            const pane_obj = pane_val.object;
            const uuid_str = (pane_obj.get("uuid") orelse continue).string;
            if (uuid_str.len != 32) continue;

            var uuid_arr: [32]u8 = undefined;
            @memcpy(&uuid_arr, uuid_str[0..32]);

            // Check for duplicate UUID - if already used, skip this float.
            if (used_uuids.contains(uuid_arr)) {
                mux.debugLog("reattachSession: duplicate UUID in floats: {s}, skipping", .{uuid_arr[0..8]});
                continue;
            }

            {
                // Try adopting from pre-collected pane_uuids first,
                // then try adopting directly from SES by UUID.
                var adopt_info: ?AdoptInfo = uuid_pane_map.get(uuid_arr);
                if (adopt_info == null) {
                    if (self.ses_client.adoptPane(uuid_arr)) |adopt_res| {
                        adopt_info = .{ .pane_id = adopt_res.pane_id };
                    } else |_| {}
                }

                const info = adopt_info orelse continue;

                // Mark this UUID as used.
                used_uuids.put(uuid_arr, {}) catch {};
                const pane = self.allocator.create(Pane) catch continue;
                const vt_fd = self.ses_client.getVtFd() orelse {
                    self.allocator.destroy(pane);
                    continue;
                };

                pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, uuid_arr) catch {
                    self.allocator.destroy(pane);
                    continue;
                };

                // Request pane info to populate pane name
                if (self.ses_client.ctl_fd) |ctl_fd| {
                    const msg = core.wire.PaneUuid{ .uuid = uuid_arr };
                    core.wire.writeControl(ctl_fd, .pane_info, std.mem.asBytes(&msg)) catch {};
                }

                // Restore float properties.
                pane.floating = true;
                pane.visible = if (pane_obj.get("visible")) |v| (v != .bool or v.bool) else true;
                pane.tab_visible = intFieldCast(u64, pane_obj, "tab_visible") orelse 0;
                pane.float_key = intFieldCast(u8, pane_obj, "float_key") orelse 0;
                pane.float_width_pct = intFieldCast(u8, pane_obj, "float_width_pct") orelse 60;
                pane.float_height_pct = intFieldCast(u8, pane_obj, "float_height_pct") orelse 60;
                pane.float_pos_x_pct = intFieldCast(u8, pane_obj, "float_pos_x_pct") orelse 50;
                pane.float_pos_y_pct = intFieldCast(u8, pane_obj, "float_pos_y_pct") orelse 50;
                pane.float_pad_x = intFieldCast(u8, pane_obj, "float_pad_x") orelse 1;
                pane.float_pad_y = intFieldCast(u8, pane_obj, "float_pad_y") orelse 0;
                pane.is_pwd = if (pane_obj.get("is_pwd")) |ip| (ip == .bool and ip.bool) else false;
                pane.sticky = if (pane_obj.get("sticky")) |s| (s == .bool and s.bool) else false;
                pane.parent_tab = if (pane_obj.get("parent_tab")) |pt| blk: {
                    if (pt != .integer or pt.integer < 0) {
                        mux.debugLog("reattachSession: parent_tab is not an integer for float pane", .{});
                        break :blk null;
                    }
                    const parent_idx: usize = @intCast(pt.integer);
                    // Validate against tabs count (will be validated again after all tabs restored)
                    break :blk parent_idx;
                } else null;

                // Re-apply float style and border color from config definition.
                // These are config pointers that can't be serialized, so we look
                // up the FloatDef by the restored float_key.
                if (pane.float_key != 0) {
                    if (self.getLayoutFloatByKey(pane.float_key)) |float_def| {
                        const style = if (float_def.style) |*s| s else if (self.config.float_style_default) |*s| s else null;
                        if (style) |s| {
                            pane.float_style = s;
                        }
                        pane.border_color = float_def.color orelse self.config.float_color;
                    }
                }

                // Restore pwd_dir for per_cwd floats.
                if (pane_obj.get("pwd_dir")) |pwd_val| {
                    if (pwd_val == .string) {
                        pane.pwd_dir = self.allocator.dupe(u8, pwd_val.string) catch null;
                    }
                }

                // Configure pane notifications.
                pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

                // Restore float title from ses memory (best-effort).
                if (self.ses_client.isConnected()) {
                    if (self.ses_client.getPaneName(uuid_arr)) |name| {
                        pane.float_title = name;
                    }
                }

                self.floats.append(self.allocator, pane) catch {
                    pane.deinit();
                    self.allocator.destroy(pane);
                    continue;
                };
            }
        }
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
    self.active_floating = if (wanted_active_floating) |idx|
        if (idx < self.floats.items.len) idx else null
    else
        null;

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

    // Signal SES that we're ready for backlog replay.
    // This triggers deferred VT reconnection to PODs, which replays their buffers.
    mux.debugLog("reattachSession: calling requestBacklogReplay", .{});
    self.ses_client.requestBacklogReplay() catch |e| {
        mux.debugLog("reattachSession: requestBacklogReplay FAILED: {s}", .{@errorName(e)});
    };
    mux.debugLog("reattachSession: requestBacklogReplay done", .{});

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

    if (self.tabs.items.len == 0) {
        mux.debugLog("reattachSession: no tabs restored, returning false", .{});
        return false;
    }

    // Restore succeeded - re-register with SES using restored UUID/name.
    // This also removes the detached session from SES (via handleBinaryRegister).
    mux.debugLog("reattachSession: calling updateSession uuid={s} name={s}", .{ self.uuid[0..8], self.session_name });
    self.ses_client.updateSession(self.uuid, self.session_name) catch |e| {
        core.logging.logError("mux", "updateSession failed in restoreLayout", e);
        mux.debugLog("reattachSession: updateSession FAILED: {s}", .{@errorName(e)});
    };

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
