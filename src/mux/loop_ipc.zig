const std = @import("std");
const posix = std.posix;
const core = @import("core");
const pop = @import("pop");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const actions = @import("loop_actions.zig");

pub fn handleSesMessage(state: *State, buffer: []u8) void {
    const conn = &(state.ses_client.conn orelse return);

    // Try to read a line from ses.
    const line = conn.recvLine(buffer) catch return;
    if (line == null) return;

    // Parse JSON message.
    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line.?, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = (root.get("type") orelse return).string;

    // Handle MUX realm notification (broadcast or targeted to this mux).
    if (std.mem.eql(u8, msg_type, "notify") or std.mem.eql(u8, msg_type, "notification")) {
        if (root.get("message")) |msg_val| {
            const msg = msg_val.string;
            // Duplicate message since we'll free parsed.
            const msg_copy = state.allocator.dupe(u8, msg) catch return;
            const duration_ms = if (root.get("timeout_ms")) |v| switch (v) {
                .integer => |i| i,
                else => state.notifications.default_duration_ms,
            } else state.notifications.default_duration_ms;
            state.notifications.showWithOptions(
                msg_copy,
                duration_ms,
                state.notifications.default_style,
                true,
            );
            state.needs_render = true;
        }
    }
    // Handle PANE realm notification (targeted to specific pane).
    else if (std.mem.eql(u8, msg_type, "pane_notification")) {
        const uuid_str = (root.get("uuid") orelse return).string;
        if (uuid_str.len != 32) return;

        var target_uuid: [32]u8 = undefined;
        @memcpy(&target_uuid, uuid_str[0..32]);

        const msg = (root.get("message") orelse return).string;
        const msg_copy = state.allocator.dupe(u8, msg) catch return;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;

        // Find the pane and show notification on it.
        var found = false;

        // Check splits in all tabs.
        for (state.tabs.items) |*tab| {
            var pane_it = tab.layout.splitIterator();
            while (pane_it.next()) |pane| {
                if (std.mem.eql(u8, &pane.*.uuid, &target_uuid)) {
                    const duration_ms = timeout_ms orelse pane.*.notifications.default_duration_ms;
                    pane.*.notifications.showWithOptions(
                        msg_copy,
                        duration_ms,
                        pane.*.notifications.default_style,
                        true,
                    );
                    found = true;
                    break;
                }
            }
            if (found) break;
        }

        // Check floats if not found.
        if (!found) {
            for (state.floats.items) |pane| {
                if (std.mem.eql(u8, &pane.uuid, &target_uuid)) {
                    const duration_ms = timeout_ms orelse pane.notifications.default_duration_ms;
                    pane.notifications.showWithOptions(
                        msg_copy,
                        duration_ms,
                        pane.notifications.default_style,
                        true,
                    );
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            // Pane not found, free the copy.
            state.allocator.free(msg_copy);
        }
        state.needs_render = true;
    }
    // Handle TAB realm notification (targeted to specific tab).
    else if (std.mem.eql(u8, msg_type, "tab_notification")) {
        const uuid_str = (root.get("uuid") orelse return).string;
        if (uuid_str.len < 8) return; // At least 8 char prefix.

        const msg = (root.get("message") orelse return).string;
        const msg_copy = state.allocator.dupe(u8, msg) catch return;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;

        // Find the tab by UUID prefix.
        var found = false;
        for (state.tabs.items) |*tab| {
            if (std.mem.startsWith(u8, &tab.uuid, uuid_str)) {
                const duration_ms = timeout_ms orelse tab.notifications.default_duration_ms;
                tab.notifications.showWithOptions(
                    msg_copy,
                    duration_ms,
                    tab.notifications.default_style,
                    true,
                );
                found = true;
                break;
            }
        }

        if (!found) {
            state.allocator.free(msg_copy);
        }
        state.needs_render = true;
    }
    // Handle pop_confirm - show confirm dialog.
    else if (std.mem.eql(u8, msg_type, "pop_confirm")) {
        const msg = (root.get("message") orelse return).string;
        const target_uuid = if (root.get("target_uuid")) |v| v.string else null;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        const opts: pop.ConfirmOptions = .{ .timeout_ms = timeout_ms };

        // Determine scope based on target_uuid.
        if (target_uuid) |uuid| {
            // Check if it matches a tab UUID.
            for (state.tabs.items, 0..) |*tab, tab_idx| {
                if (std.mem.startsWith(u8, &tab.uuid, uuid)) {
                    tab.popups.showConfirmOwned(msg, opts) catch return;
                    state.pending_pop_response = true;
                    state.pending_pop_scope = .tab;
                    state.pending_pop_tab = tab_idx;
                    state.needs_render = true;
                    return;
                }
            }
            // Check if it matches a pane UUID (tiled splits).
            for (state.tabs.items) |*tab| {
                var iter = tab.layout.splits.valueIterator();
                while (iter.next()) |pane| {
                    if (std.mem.startsWith(u8, &pane.*.uuid, uuid)) {
                        pane.*.popups.showConfirmOwned(msg, opts) catch return;
                        state.pending_pop_response = true;
                        state.pending_pop_scope = .pane;
                        state.pending_pop_pane = pane.*;
                        state.needs_render = true;
                        return;
                    }
                }
            }
            // Check if it matches a float pane UUID.
            for (state.floats.items) |pane| {
                if (std.mem.startsWith(u8, &pane.uuid, uuid)) {
                    pane.popups.showConfirmOwned(msg, opts) catch return;
                    state.pending_pop_response = true;
                    state.pending_pop_scope = .pane;
                    state.pending_pop_pane = pane;
                    state.needs_render = true;
                    return;
                }
            }
        }
        // Default: MUX level (blocks everything).
        state.popups.showConfirmOwned(msg, opts) catch return;
        state.pending_pop_response = true;
        state.pending_pop_scope = .mux;
        state.needs_render = true;
    }
    // Handle pop_choose - show picker dialog.
    else if (std.mem.eql(u8, msg_type, "pop_choose")) {
        const msg = (root.get("message") orelse return).string;
        const items_val = root.get("items") orelse return;
        if (items_val != .array) return;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;

        // Convert JSON array to string slice.
        var items_list: std.ArrayList([]const u8) = .empty;
        defer items_list.deinit(state.allocator);

        for (items_val.array.items) |item| {
            if (item == .string) {
                const duped = state.allocator.dupe(u8, item.string) catch continue;
                items_list.append(state.allocator, duped) catch {
                    state.allocator.free(duped);
                    continue;
                };
            }
        }

        if (items_list.items.len > 0) {
            state.popups.showPickerOwned(items_list.items, .{ .title = msg, .timeout_ms = timeout_ms }) catch {
                // Free items on failure.
                for (items_list.items) |item| {
                    state.allocator.free(item);
                }
                return;
            };
            state.pending_pop_response = true;
            state.needs_render = true;
        }
    }
}

/// Send popup response back to ses (for CLI-triggered popups).
pub fn sendPopResponse(state: *State) void {
    if (!state.pending_pop_response) return;
    state.pending_pop_response = false;

    // Get the connection to ses.
    const conn = &(state.ses_client.conn orelse return);

    // Get the correct PopupManager based on scope.
    var popups: *pop.PopupManager = switch (state.pending_pop_scope) {
        .mux => &state.popups,
        .tab => &state.tabs.items[state.pending_pop_tab].popups,
        .pane => if (state.pending_pop_pane) |pane| &pane.popups else &state.popups,
    };

    // Check what kind of response we need to send.
    var buf: [256]u8 = undefined;

    // Try to get confirm result.
    if (popups.getConfirmResult()) |confirmed| {
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"confirmed\":{}}}", .{confirmed}) catch return;
        conn.sendLine(msg) catch {};
        popups.clearResults();
        return;
    }

    // Try to get picker result.
    if (popups.getPickerResult()) |selected| {
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"selected\":{d}}}", .{selected}) catch return;
        conn.sendLine(msg) catch {};
        popups.clearResults();
        return;
    }

    // Picker was cancelled (result is null but wasPickerCancelled is true).
    if (popups.wasPickerCancelled()) {
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"cancelled\":true}}", .{}) catch return;
        conn.sendLine(msg) catch {};
        popups.clearResults();
        return;
    }

    // Confirm was cancelled (result is false - but we should have caught it above)
    // This handles edge cases.
    const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"cancelled\":true}}", .{}) catch return;
    conn.sendLine(msg) catch {};
    popups.clearResults();
}

pub fn handleIpcConnection(state: *State, buffer: []u8) void {
    const server = &(state.ipc_server orelse return);

    // Try to accept a connection (non-blocking).
    const conn_opt = server.tryAccept() catch return;
    if (conn_opt == null) return;

    var conn = conn_opt.?;
    var keep_open = false;
    defer if (!keep_open) conn.close();

    // Read message.
    const line = conn.recvLine(buffer) catch return;
    if (line == null) return;

    // Parse JSON message.
    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line.?, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = (root.get("type") orelse return).string;

    if (std.mem.eql(u8, msg_type, "notify")) {
        if (root.get("message")) |msg_val| {
            const msg = msg_val.string;
            const msg_copy = state.allocator.dupe(u8, msg) catch return;
            state.notifications.showWithOptions(
                msg_copy,
                state.notifications.default_duration_ms,
                state.notifications.default_style,
                true,
            );
            state.needs_render = true;
        }
    } else if (std.mem.eql(u8, msg_type, "float")) {
        const command_val = root.get("command") orelse {
            conn.sendLine("{\"type\":\"error\",\"message\":\"missing_command\"}") catch {};
            return;
        };
        const command = command_val.string;
        if (command.len == 0) {
            conn.sendLine("{\"type\":\"error\",\"message\":\"empty_command\"}") catch {};
            return;
        }

        const wait_for_exit = if (root.get("wait")) |v| v.bool else false;
        const isolated = if (root.get("isolated")) |v| v.bool else false;

        var result_path: ?[]u8 = null;
        defer if (result_path) |path| state.allocator.free(path);
        var env_list: std.ArrayList([]const u8) = .empty;
        defer {
            for (env_list.items) |env_line| {
                state.allocator.free(env_line);
            }
            env_list.deinit(state.allocator);
        }
        var extra_env_list: std.ArrayList([]const u8) = .empty;
        defer extra_env_list.deinit(state.allocator);
        var owned_extra_env: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_extra_env.items) |owned| {
                state.allocator.free(owned);
            }
            owned_extra_env.deinit(state.allocator);
        }

        if (root.get("env_file")) |env_file_val| {
            if (env_file_val == .string and env_file_val.string.len > 0) {
                const file = std.fs.cwd().openFile(env_file_val.string, .{}) catch null;
                if (file) |env_file| {
                    defer env_file.close();
                    const content = env_file.readToEndAlloc(state.allocator, 4 * 1024 * 1024) catch null;
                    if (content) |buf| {
                        defer state.allocator.free(buf);
                        var it = std.mem.splitScalar(u8, buf, '\n');
                        while (it.next()) |entry_line| {
                            if (entry_line.len == 0) continue;
                            const owned_line = state.allocator.dupe(u8, entry_line) catch null;
                            if (owned_line) |line_copy| {
                                env_list.append(state.allocator, line_copy) catch {};
                            }
                        }
                    }
                }
                std.fs.cwd().deleteFile(env_file_val.string) catch {};
            }
        }

        if (root.get("env")) |env_val| {
            if (env_val == .array) {
                for (env_val.array.items) |entry| {
                    if (entry == .string and entry.string.len > 0) {
                        env_list.append(state.allocator, entry.string) catch {};
                    }
                }
            }
        }

        if (root.get("extra_env")) |extra_val| {
            if (extra_val == .array) {
                for (extra_val.array.items) |entry| {
                    if (entry == .string and entry.string.len > 0) {
                        extra_env_list.append(state.allocator, entry.string) catch {};
                    }
                }
            }
        }

        if (isolated) {
            const entry = state.allocator.dupe(u8, "HEXE_POD_ISOLATE=1") catch null;
            if (entry) |env_entry| {
                owned_extra_env.append(state.allocator, env_entry) catch {};
                extra_env_list.append(state.allocator, env_entry) catch {};
            }
        }

        if (wait_for_exit) {
            if (root.get("result_file")) |rf_val| {
                if (rf_val == .string and rf_val.string.len > 0) {
                    result_path = state.allocator.dupe(u8, rf_val.string) catch null;
                }
            }
            if (result_path == null) {
                const tmp_uuid = core.ipc.generateUuid();
                result_path = std.fmt.allocPrint(state.allocator, "/tmp/hexe-float-{s}.result", .{tmp_uuid}) catch null;
            }
            if (result_path) |path| {
                const entry = std.fmt.allocPrint(state.allocator, "HEXE_FLOAT_RESULT_FILE={s}", .{path}) catch null;
                if (entry) |env_entry| {
                    owned_extra_env.append(state.allocator, env_entry) catch {};
                    extra_env_list.append(state.allocator, env_entry) catch {};
                }
            }
        }

        const env_items: ?[]const []const u8 = if (env_list.items.len > 0) env_list.items else null;
        const extra_env_items: ?[]const []const u8 = if (extra_env_list.items.len > 0) extra_env_list.items else null;

        const command_to_run = command;

        const title = if (root.get("title")) |tv|
            if (tv == .string and tv.string.len > 0) tv.string else null
        else
            null;

        const old_uuid = state.getCurrentFocusedUuid();
        const focused_pane = if (state.active_floating) |idx| blk: {
            if (idx < state.floats.items.len) break :blk state.floats.items[idx];
            break :blk @as(?*Pane, null);
        } else state.currentLayout().getFocusedPane();
        var spawn_cwd = if (focused_pane) |pane| state.getSpawnCwd(pane) else null;
        if (root.get("cwd")) |cwd_val| {
            if (cwd_val == .string and cwd_val.string.len > 0) {
                spawn_cwd = cwd_val.string;
            }
        }

        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                state.syncPaneUnfocus(state.floats.items[idx]);
            }
        } else if (state.currentLayout().getFocusedPane()) |tiled| {
            state.syncPaneUnfocus(tiled);
        }

        const use_pod = (!wait_for_exit) or isolated;
        const new_uuid = actions.createAdhocFloat(state, command_to_run, title, spawn_cwd, env_items, extra_env_items, use_pod) catch |err| {
            const msg = std.fmt.allocPrint(state.allocator, "{{\"type\":\"error\",\"message\":\"{s}\"}}", .{@errorName(err)}) catch return;
            defer state.allocator.free(msg);
            conn.sendLine(msg) catch {};
            return;
        };

        if (state.floats.items.len > 0) {
            state.syncPaneFocus(state.floats.items[state.floats.items.len - 1], old_uuid);
        }
        state.needs_render = true;

        if (wait_for_exit) {
            if (state.floats.items.len > 0) {
                state.floats.items[state.floats.items.len - 1].capture_output = true;
            }
            const stored_path = if (result_path) |path| state.allocator.dupe(u8, path) catch null else null;
            state.pending_float_requests.put(new_uuid, .{ .fd = conn.fd, .result_path = stored_path }) catch {
                conn.sendLine("{\"type\":\"error\",\"message\":\"float_wait_failed\"}") catch {};
                return;
            };
            keep_open = true;
        } else {
            var resp_buf: [96]u8 = undefined;
            const response = std.fmt.bufPrint(&resp_buf, "{{\"type\":\"float_created\",\"uuid\":\"{s}\"}}", .{new_uuid}) catch return;
            conn.sendLine(response) catch {};
        }
    } else if (std.mem.eql(u8, msg_type, "exit_intent")) {
        // Shell asks mux permission before exiting.
        // This avoids the "shell died -> respawn" hack for the last split.

        // If this isn't a hexe mux session yet, or state is weird, just allow.
        if (state.tabs.items.len == 0) {
            conn.sendLine("{\"type\":\"exit_intent_result\",\"allow\":true}") catch {};
            return;
        }

        const is_last_split = (state.currentLayout().splitCount() <= 1 and state.tabs.items.len <= 1);
        if (!is_last_split or !state.config.confirm_on_exit) {
            conn.sendLine("{\"type\":\"exit_intent_result\",\"allow\":true}") catch {};
            return;
        }

        // Need confirmation. Only one pending request at a time.
        if (state.pending_action != null or state.popups.isBlocked() or state.pending_exit_intent_fd != null) {
            conn.sendLine("{\"type\":\"exit_intent_result\",\"allow\":false}") catch {};
            return;
        }

        state.pending_action = .exit_intent;
        state.pending_exit_intent_fd = conn.fd;
        state.popups.showConfirm("Exit mux?", .{}) catch {
            // If popup fails for any reason, default to allow.
            state.pending_action = null;
            state.pending_exit_intent_fd = null;
            conn.sendLine("{\"type\":\"exit_intent_result\",\"allow\":true}") catch {};
            return;
        };
        state.needs_render = true;
        keep_open = true;
    } else if (std.mem.eql(u8, msg_type, "shell_event")) {
        const uuid_str = if (root.get("pane_uuid")) |v|
            if (v == .string) v.string else ""
        else
            "";
        if (uuid_str.len != 32) {
            conn.sendLine("{\"type\":\"error\",\"message\":\"invalid_uuid\"}") catch {};
            return;
        }

        var uuid: [32]u8 = undefined;
        @memcpy(&uuid, uuid_str[0..32]);

        const cmd = if (root.get("cmd")) |v|
            if (v == .string) v.string else null
        else
            null;
        const cwd = if (root.get("cwd")) |v|
            if (v == .string) v.string else null
        else
            null;
        const status_opt: ?i32 = if (root.get("status")) |v| switch (v) {
            .integer => |i| @intCast(i),
            else => null,
        } else null;
        const dur_opt: ?u64 = if (root.get("duration_ms")) |v| switch (v) {
            .integer => |i| @intCast(@max(@as(i64, 0), i)),
            else => null,
        } else null;

        const jobs_opt: ?u16 = if (root.get("jobs")) |v| switch (v) {
            .integer => |i| @intCast(@max(@as(i64, 0), i)),
            else => null,
        } else null;

        // Job count delta notifications (only on 0<->nonzero transitions).
        const old_jobs: ?u16 = if (state.pane_shell.get(uuid)) |info| info.jobs else null;
        if (jobs_opt) |new_jobs| {
            if (old_jobs) |old| {
                if (old == 0 and new_jobs > 0) {
                    var msg_buf: [64]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Background jobs: {d}", .{new_jobs}) catch null;
                    if (msg) |m| {
                        state.notifications.show(m);
                        state.needs_render = true;
                    }
                } else if (old > 0 and new_jobs == 0) {
                    state.notifications.show("Background jobs finished");
                    state.needs_render = true;
                }
            }
        }

        state.setPaneShell(uuid, cmd, cwd, status_opt, dur_opt, jobs_opt);

        // Forward to ses so `hexe com info` can show it.
        state.ses_client.updatePaneShell(uuid, cmd, cwd, status_opt, dur_opt, jobs_opt) catch {};

        // Shell events often arrive with no pane output; force a re-render so
        // statusbar modules (cmd/jobs/etc) update immediately.
        state.needs_render = true;

        conn.sendLine("{\"type\":\"ok\"}") catch {};
    }
}
