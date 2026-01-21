const std = @import("std");
const core = @import("core");
const ipc = core.ipc;

const print = std.debug.print;

pub fn runList(allocator: std.mem.Allocator, details: bool) !void {
    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    if (details) {
        try conn.sendLine("{\"type\":\"status\",\"full\":true}");
    } else {
        try conn.sendLine("{\"type\":\"status\"}");
    }

    var buf: [65536]u8 = undefined;
    const line = try conn.recvLine(&buf);
    if (line == null) {
        print("No response from daemon\n", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line.?, .{}) catch {
        print("Invalid response from daemon\n", .{});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Connected muxes
    if (root.get("clients")) |clients_val| {
        const clients = clients_val.array;
        if (clients.items.len > 0) {
            print("Connected muxes: {d}\n", .{clients.items.len});
            for (clients.items) |client_val| {
                const c = client_val.object;
                const id = c.get("id").?.integer;
                const panes = c.get("panes").?.array;
                const name = if (c.get("session_name")) |n| n.string else "unknown";
                const sid = if (c.get("session_id")) |s| s.string else null;

                if (sid) |session_id| {
                    print("  {s} [{s}] (mux #{d}, {d} panes)\n", .{ name, session_id[0..8], id, panes.items.len });
                } else {
                    print("  {s} (mux #{d}, {d} panes)\n", .{ name, id, panes.items.len });
                }

                if (c.get("mux_state")) |mux_state_val| {
                    printMuxTree(allocator, mux_state_val.string, "    ");
                }
            }
        }
    }

    // Detached sessions
    if (root.get("detached_sessions")) |sessions_val| {
        const sessions = sessions_val.array;
        if (sessions.items.len > 0) {
            print("\nDetached sessions: {d}\n", .{sessions.items.len});
            for (sessions.items) |sess_val| {
                const s = sess_val.object;
                const sid = s.get("session_id").?.string;
                const pane_count = s.get("pane_count").?.integer;
                const name = if (s.get("session_name")) |n| n.string else "unknown";

                print("  {s} [{s}] {d} panes - reattach: hexe mux attach {s}\n", .{ name, sid[0..8], pane_count, name });

                if (s.get("mux_state")) |mux_state_val| {
                    printMuxTree(allocator, mux_state_val.string, "    ");
                }
            }
        }
    }

    // Orphaned panes
    if (root.get("orphaned")) |orphaned_val| {
        const orphaned = orphaned_val.array;
        if (orphaned.items.len > 0) {
            print("\nOrphaned panes: {d}\n", .{orphaned.items.len});
            for (orphaned.items) |pane_val| {
                const p = pane_val.object;
                const uuid = p.get("uuid").?.string;
                const pid = p.get("pid").?.integer;
                print("  [{s}] pid={d}\n", .{ uuid[0..8], pid });
            }
        }
    }

    // Sticky panes
    if (root.get("sticky")) |sticky_val| {
        const sticky = sticky_val.array;
        if (sticky.items.len > 0) {
            print("\nSticky panes: {d}\n", .{sticky.items.len});
            for (sticky.items) |pane_val| {
                const p = pane_val.object;
                const uuid = p.get("uuid").?.string;
                const pid = p.get("pid").?.integer;
                print("  [{s}] pid={d}", .{ uuid[0..8], pid });
                if (p.get("pwd")) |pwd| {
                    print(" pwd={s}", .{pwd.string});
                }
                if (p.get("key")) |key| {
                    print(" key={s}", .{key.string});
                }
                print("\n", .{});
            }
        }
    }
}

pub fn runInfo(allocator: std.mem.Allocator, uuid_arg: []const u8, show_creator: bool, show_last: bool) !void {
    // Connect to ses
    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    var buf: [1024]u8 = undefined;
    var resp_buf: [4096]u8 = undefined;
    var uuid_buf: [32]u8 = undefined;

    // Determine which UUID to query
    var target_uuid: []const u8 = undefined;

    if (uuid_arg.len > 0) {
        // Explicit UUID provided
        target_uuid = uuid_arg;
    } else if (show_creator or show_last) {
        // Need current pane UUID first, then get creator/last from it
        const current_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("--creator/--last requires running inside hexe mux\n", .{});
            return;
        };

        // Query current pane to get creator/last UUID
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{current_uuid});
        try conn.sendLine(msg);

        const response = try conn.recvLine(&resp_buf);
        if (response == null) {
            print("No response from daemon\n", .{});
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.?, .{}) catch {
            print("Invalid response from daemon\n", .{});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        if (show_creator) {
            if (root.get("created_from")) |cf| {
                if (cf.string.len == 32) {
                    @memcpy(&uuid_buf, cf.string[0..32]);
                    target_uuid = &uuid_buf;
                } else {
                    print("Current pane has no creator\n", .{});
                    return;
                }
            } else {
                print("Current pane has no creator\n", .{});
                return;
            }
        } else if (show_last) {
            if (root.get("focused_from")) |ff| {
                if (ff.string.len == 32) {
                    @memcpy(&uuid_buf, ff.string[0..32]);
                    target_uuid = &uuid_buf;
                } else {
                    print("Current pane has no last focused\n", .{});
                    return;
                }
            } else {
                print("Current pane has no last focused\n", .{});
                return;
            }
        }
    } else {
        // Default: query current pane
        const pane_uuid = std.posix.getenv("HEXE_PANE_UUID");
        if (pane_uuid == null) {
            print("Not inside a hexe mux session (use --uuid to query specific pane)\n", .{});
            return;
        }
        target_uuid = pane_uuid.?;
    }

    // Query the target pane
    const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{target_uuid});
    try conn.sendLine(msg);

    const response = try conn.recvLine(&resp_buf);
    if (response == null) {
        print("No response from daemon\n", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.?, .{}) catch {
        print("Invalid response from daemon\n", .{});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Check for error
    if (root.get("type")) |t| {
        if (std.mem.eql(u8, t.string, "error")) {
            if (root.get("message")) |m| {
                print("Error: {s}\n", .{m.string});
            }
            return;
        }
    }

    // Show all info
    print("Pane Info:\n", .{});
    print("  UUID: {s}\n", .{target_uuid});

    if (root.get("pid")) |pid| {
        print("  Shell PID: {d}\n", .{pid.integer});
    }
    if (root.get("base_process")) |proc| {
        if (root.get("base_pid")) |pid| {
            print("  Base Process: {s} (pid={d})\n", .{ proc.string, pid.integer });
        } else {
            print("  Base Process: {s}\n", .{proc.string});
        }
    }
    if (root.get("active_process")) |proc| {
        if (root.get("active_pid")) |pid| {
            print("  Active Process: {s} (pid={d})\n", .{ proc.string, pid.integer });
        } else {
            print("  Active Process: {s}\n", .{proc.string});
        }
    } else if (root.get("fg_process")) |proc| {
        if (root.get("fg_pid")) |pid| {
            print("  Process: {s} (pid={d})\n", .{ proc.string, pid.integer });
        } else {
            print("  Process: {s}\n", .{proc.string});
        }
    }
    if (root.get("cwd")) |cwd| {
        print("  CWD: {s}\n", .{cwd.string});
    }
    if (root.get("tty")) |tty| {
        print("  TTY: {s}\n", .{tty.string});
    }
    if (root.get("cols")) |cols| {
        if (root.get("rows")) |rows| {
            print("  Window: {d}x{d}\n", .{ cols.integer, rows.integer });
        }
    }
    if (root.get("session_name")) |sn| {
        print("  Session: {s}\n", .{sn.string});
    }
    if (root.get("created_from")) |cf| {
        print("  Creator: {s}\n", .{cf.string[0..8]});
    }
    if (root.get("focused_from")) |ff| {
        print("  Last: {s}\n", .{ff.string[0..8]});
    }
    if (root.get("layout_path")) |path| {
        print("  Layout: {s}\n", .{path.string});
    }
    if (root.get("socket_path")) |path| {
        print("  Socket: {s}\n", .{path.string});
    }
    if (root.get("is_focused")) |f| {
        print("  Focused: {}\n", .{f.bool});
    }
    if (root.get("pane_type")) |pt| {
        print("  Type: {s}\n", .{pt.string});
    }
    if (root.get("cursor_x")) |cx| {
        if (root.get("cursor_y")) |cy| {
            print("  Cursor: {d},{d}\n", .{ cx.integer, cy.integer });
        }
    }
    if (root.get("cursor_style")) |cs| {
        print("  Cursor Style: {d}\n", .{cs.integer});
    }
    if (root.get("cursor_visible")) |cv| {
        print("  Cursor Visible: {}\n", .{cv.bool});
    }
    if (root.get("alt_screen")) |alt| {
        print("  Alt Screen: {}\n", .{alt.bool});
    }
}

pub fn runNotify(allocator: std.mem.Allocator, uuid: []const u8, creator: bool, last: bool, broadcast: bool, message: []const u8) !void {
    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    var buf: [4096]u8 = undefined;

    var target_uuid: ?[]const u8 = null;
    var uuid_buf: [32]u8 = undefined; // Buffer to copy UUID into (outlives JSON)

    if (uuid.len > 0) {
        target_uuid = uuid;
    } else if (creator or last) {
        // Query pane_info to get creator or last focused pane
        const current_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: --creator/--last requires running inside hexe mux\n", .{});
            return;
        };

        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{current_uuid});
        try conn.sendLine(msg);

        var resp_buf: [4096]u8 = undefined;
        if (try conn.recvLine(&resp_buf)) |r| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch {
                print("Error: invalid response from daemon\n", .{});
                return;
            };
            defer parsed.deinit();

            const root = parsed.value.object;
            if (root.get("type")) |t| {
                if (std.mem.eql(u8, t.string, "pane_info")) {
                    if (creator) {
                        if (root.get("created_from")) |cf| {
                            if (cf.string.len == 32) {
                                @memcpy(&uuid_buf, cf.string[0..32]);
                                target_uuid = &uuid_buf;
                            }
                        } else {
                            print("Error: current pane has no creator\n", .{});
                            return;
                        }
                    } else if (last) {
                        if (root.get("focused_from")) |ff| {
                            if (ff.string.len == 32) {
                                @memcpy(&uuid_buf, ff.string[0..32]);
                                target_uuid = &uuid_buf;
                            }
                        } else {
                            print("Error: current pane has no previous focus\n", .{});
                            return;
                        }
                    }
                } else {
                    print("Error: pane not found\n", .{});
                    return;
                }
            }
        }
    } else if (!broadcast) {
        target_uuid = std.posix.getenv("HEXE_PANE_UUID");
    }

    if (target_uuid) |t| {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"targeted_notify\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}", .{ t, message });
        try conn.sendLine(msg);
    } else {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"broadcast_notify\",\"message\":\"{s}\"}}", .{message});
        try conn.sendLine(msg);
    }

    var resp_buf: [1024]u8 = undefined;
    if (try conn.recvLine(&resp_buf)) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "not_found")) {
                print("Target UUID not found\n", .{});
            } else if (std.mem.eql(u8, t.string, "ok")) {
                if (parsed.value.object.get("realm")) |realm| {
                    print("Notification sent to {s}\n", .{realm.string});
                } else {
                    print("Notification sent\n", .{});
                }
            }
        }
    }
}

pub fn printMuxTree(allocator: std.mem.Allocator, json: []const u8, indent: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const floats_arr = if (root.get("floats")) |fv| fv.array.items else &[_]std.json.Value{};

    if (root.get("tabs")) |tabs_val| {
        const tabs = tabs_val.array;
        const active = if (root.get("active_tab")) |at| @as(usize, @intCast(at.integer)) else 0;

        for (tabs.items, 0..) |tab_val, ti| {
            const tab = tab_val.object;
            const name = if (tab.get("name")) |n| n.string else "tab";
            const tab_uuid = if (tab.get("uuid")) |u| u.string else "?";
            const marker = if (ti == active) "*" else " ";
            print("{s}{s} Tab: {s} [{s}]\n", .{ indent, marker, name, tab_uuid[0..@min(8, tab_uuid.len)] });

            if (tab.get("splits")) |splits_val| {
                for (splits_val.array.items) |split_val| {
                    const split = split_val.object;
                    const uuid = if (split.get("uuid")) |u| u.string else "?";
                    const pid = if (split.get("id")) |id| @as(i64, id.integer) else 0;
                    const focused = if (split.get("focused")) |f| f.bool else false;
                    const fm = if (focused) ">" else " ";
                    print("{s}  {s} Split {d} [{s}]\n", .{ indent, fm, pid, uuid[0..@min(8, uuid.len)] });
                }
            }

            for (floats_arr, 0..) |float_val, fi| {
                const float = float_val.object;
                if (float.get("parent_tab")) |pt| {
                    if (pt == .integer and @as(usize, @intCast(pt.integer)) == ti) {
                        const uuid = if (float.get("uuid")) |u| u.string else "?";
                        const visible = if (float.get("visible")) |v| v.bool else false;
                        const vm = if (visible) "*" else " ";
                        print("{s}  {s} Float {d} [{s}]\n", .{ indent, vm, fi, uuid[0..@min(8, uuid.len)] });
                    }
                }
            }
        }
    }

    var has_global_floats = false;
    for (floats_arr) |float_val| {
        const float = float_val.object;
        if (float.get("parent_tab") == null) {
            has_global_floats = true;
            break;
        }
    }

    if (has_global_floats) {
        print("{s}Floats (global):\n", .{indent});
        for (floats_arr, 0..) |float_val, i| {
            const float = float_val.object;
            if (float.get("parent_tab") == null) {
                const uuid = if (float.get("uuid")) |u| u.string else "?";
                const visible = if (float.get("visible")) |v| v.bool else false;
                const vm = if (visible) "*" else " ";
                print("{s}  {s} Float {d} [{s}]\n", .{ indent, vm, i, uuid[0..@min(8, uuid.len)] });
            }
        }
    }
}

pub fn runSend(allocator: std.mem.Allocator, uuid: []const u8, creator: bool, last: bool, broadcast: bool, enter: bool, ctrl: []const u8, text: []const u8) !void {
    // Build the data to send
    var data_buf: [4096]u8 = undefined;
    var data_len: usize = 0;

    // Handle --ctrl option (e.g., --ctrl c sends Ctrl+C)
    if (ctrl.len > 0) {
        if (ctrl.len == 1 and ctrl[0] >= 'a' and ctrl[0] <= 'z') {
            data_buf[0] = ctrl[0] - 'a' + 1; // Ctrl+a = 0x01, Ctrl+c = 0x03, etc.
            data_len = 1;
        } else if (ctrl.len == 1 and ctrl[0] >= 'A' and ctrl[0] <= 'Z') {
            data_buf[0] = ctrl[0] - 'A' + 1;
            data_len = 1;
        } else {
            print("Error: --ctrl requires a single letter (a-z)\n", .{});
            return;
        }
    } else if (text.len > 0) {
        if (text.len > data_buf.len - 1) {
            print("Error: text too long\n", .{});
            return;
        }
        @memcpy(data_buf[0..text.len], text);
        data_len = text.len;
    }

    // Append newline if --enter
    if (enter and data_len < data_buf.len) {
        data_buf[data_len] = '\n';
        data_len += 1;
    }

    if (data_len == 0) {
        print("Error: no data to send (use text argument, --ctrl, or --enter)\n", .{});
        return;
    }

    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    var buf: [4096]u8 = undefined;

    var target_uuid: ?[]const u8 = null;
    var uuid_buf: [32]u8 = undefined;

    if (uuid.len > 0) {
        target_uuid = uuid;
    } else if (creator or last) {
        // Query pane_info to get creator or last focused pane
        const current_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: --creator/--last requires running inside hexe mux\n", .{});
            return;
        };

        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pane_info\",\"uuid\":\"{s}\"}}", .{current_uuid});
        try conn.sendLine(msg);

        var resp_buf: [4096]u8 = undefined;
        if (try conn.recvLine(&resp_buf)) |r| {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch {
                print("Error: invalid response from daemon\n", .{});
                return;
            };
            defer parsed.deinit();

            const root = parsed.value.object;
            if (root.get("type")) |t| {
                if (std.mem.eql(u8, t.string, "pane_info")) {
                    if (creator) {
                        if (root.get("created_from")) |cf| {
                            if (cf.string.len == 32) {
                                @memcpy(&uuid_buf, cf.string[0..32]);
                                target_uuid = &uuid_buf;
                            }
                        } else {
                            print("Error: current pane has no creator\n", .{});
                            return;
                        }
                    } else if (last) {
                        if (root.get("focused_from")) |ff| {
                            if (ff.string.len == 32) {
                                @memcpy(&uuid_buf, ff.string[0..32]);
                                target_uuid = &uuid_buf;
                            }
                        } else {
                            print("Error: current pane has no previous focus\n", .{});
                            return;
                        }
                    }
                } else {
                    print("Error: pane not found\n", .{});
                    return;
                }
            }
        }
    } else if (!broadcast) {
        target_uuid = std.posix.getenv("HEXE_PANE_UUID");
    }

    // Build send_keys request with hex-encoded data
    // Manually encode to hex
    var hex_buf: [8192]u8 = undefined;
    for (data_buf[0..data_len], 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    const hex_data = hex_buf[0 .. data_len * 2];

    if (target_uuid) |t| {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"send_keys\",\"uuid\":\"{s}\",\"hex\":\"{s}\"}}", .{ t, hex_data });
        try conn.sendLine(msg);
    } else if (broadcast) {
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"send_keys\",\"broadcast\":true,\"hex\":\"{s}\"}}", .{hex_data});
        try conn.sendLine(msg);
    } else {
        print("Error: no target specified (use --uuid, --creator, --last, --broadcast, or run inside mux)\n", .{});
        return;
    }

    var resp_buf: [1024]u8 = undefined;
    if (try conn.recvLine(&resp_buf)) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "error")) {
                if (parsed.value.object.get("message")) |m| {
                    print("Error: {s}\n", .{m.string});
                }
            } else if (std.mem.eql(u8, t.string, "ok")) {
                // Success - silent
            } else if (std.mem.eql(u8, t.string, "not_found")) {
                print("Target pane not found\n", .{});
            }
        }
    }
}
