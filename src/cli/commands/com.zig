const std = @import("std");
const core = @import("core");
const ipc = core.ipc;

pub const runMuxFloat = @import("mux_float.zig").runMuxFloat;

const print = std.debug.print;

const ansi = struct {
    pub const RESET = "\x1b[0m";
    pub const DIM = "\x1b[2m";
    pub const BOLD = "\x1b[1m";

    pub const SYM = "\x1b[38;5;220m"; // yellow
    pub const MUX = "\x1b[38;5;45m"; // cyan
    pub const TAB = "\x1b[38;5;39m"; // blue
    pub const SPLIT = "\x1b[38;5;42m"; // green
    pub const FLOAT = "\x1b[38;5;171m"; // magenta
    pub const NAME = "\x1b[38;5;255m"; // bright white
    pub const UUID = "\x1b[38;5;244m"; // gray
};

fn printTreeNode(prefix: []const u8, symbol: []const u8, type_color: []const u8, type_str: []const u8, name: []const u8, uuid8: []const u8) void {
    // Format: [symbol][type][name][uuid]
    print(
        "{s}{s}{s}{s} {s}{s}{s} {s}{s}{s} [{s}{s}{s}]\n",
        .{
            prefix,
            ansi.SYM,
            symbol,
            ansi.RESET,
            type_color,
            type_str,
            ansi.RESET,
            ansi.NAME,
            name,
            ansi.RESET,
            ansi.UUID,
            uuid8,
            ansi.RESET,
        },
    );
}

pub fn runList(allocator: std.mem.Allocator, details: bool) !void {
    const inst = std.posix.getenv("HEXE_INSTANCE");
    if (inst) |name| {
        if (name.len > 0) {
            print("Instance: {s}\n", .{name});
        } else {
            print("Instance: default\n", .{});
        }
    } else {
        print("Instance: default\n", .{});
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
            for (clients.items, 0..) |client_val, ci| {
                const c = client_val.object;
                const id = c.get("id").?.integer;
                const panes = c.get("panes").?.array;
                const name = if (c.get("session_name")) |n| n.string else "unknown";
                const sid = if (c.get("session_id")) |s| s.string else null;

                const is_last_client = (ci + 1 == clients.items.len);
                const branch = if (is_last_client) "└" else "├";
                const child_prefix = if (is_last_client) "   " else "│  ";

                if (sid) |session_id| {
                    var mux_line: [256]u8 = undefined;
                    const prefix = std.fmt.bufPrint(&mux_line, "{s}─ ", .{branch}) catch "";
                    // mux uuid uses session_id prefix for stability
                    printTreeNode(prefix, " ", ansi.MUX, "mux", name, session_id[0..8]);
                    _ = id;
                } else {
                    var mux_line: [256]u8 = undefined;
                    const prefix = std.fmt.bufPrint(&mux_line, "{s}─ ", .{branch}) catch "";
                    printTreeNode(prefix, " ", ansi.MUX, "mux", name, "????????");
                    _ = id;
                }

                if (c.get("mux_state")) |mux_state_val| {
                    var pane_names = std.StringHashMap([]const u8).init(allocator);
                    defer pane_names.deinit();

                    for (panes.items) |pane_val| {
                        const p = pane_val.object;
                        const uuid = p.get("uuid").?.string;
                        if (p.get("name")) |n| {
                            pane_names.put(uuid, n.string) catch {};
                        }
                    }

                    printMuxTree(allocator, mux_state_val.string, child_prefix, &pane_names);
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
                    printMuxTree(allocator, mux_state_val.string, "    ", null);
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
                if (p.get("name")) |n| {
                    print("  [{s}] {s} pid={d}\n", .{ uuid[0..8], n.string, pid });
                } else {
                    print("  [{s}] pid={d}\n", .{ uuid[0..8], pid });
                }
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
    if (root.get("name")) |n| {
        print("  Name: {s}\n", .{n.string});
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

    if (root.get("last_cmd")) |cmd| {
        print("  Last Cmd: {s}\n", .{cmd.string});
    }
    if (root.get("last_status")) |st| {
        print("  Last Status: {d}\n", .{st.integer});
    }
    if (root.get("last_duration_ms")) |d| {
        print("  Last Duration: {d}ms\n", .{d.integer});
    }
    if (root.get("last_jobs")) |j| {
        print("  Last Jobs: {d}\n", .{j.integer});
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

pub fn printMuxTree(allocator: std.mem.Allocator, json: []const u8, indent: []const u8, pane_name_map: ?*const std.StringHashMap([]const u8)) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const floats_arr = if (root.get("floats")) |fv| fv.array.items else &[_]std.json.Value{};

    const active_tab: usize = if (root.get("active_tab")) |at| @as(usize, @intCast(at.integer)) else 0;

    // Precompute global floats (no parent_tab).
    var global_floats: std.ArrayList(usize) = .empty;
    defer global_floats.deinit(allocator);
    for (floats_arr, 0..) |float_val, fi| {
        const float = float_val.object;
        if (float.get("parent_tab") == null) {
            global_floats.append(allocator, fi) catch {};
        }
    }

    const tabs_items = if (root.get("tabs")) |tv| tv.array.items else &[_]std.json.Value{};

    // Top-level children under mux: tabs, then global floats.
    const top_count: usize = tabs_items.len + global_floats.items.len;
    var top_index: usize = 0;

    // Tabs
    for (tabs_items, 0..) |tab_val, ti| {
        const tab = tab_val.object;
        const tname = if (tab.get("name")) |n| n.string else "tab";
        const tab_uuid = if (tab.get("uuid")) |u| u.string else "?";
        const marker = if (ti == active_tab) "*" else " ";

        const is_last_top = (top_index + 1 == top_count);
        const branch = if (is_last_top) "└" else "├";

        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}{s}─ ", .{ indent, branch }) catch indent;
        printTreeNode(prefix, marker, ansi.TAB, "tab", tname, tab_uuid[0..@min(8, tab_uuid.len)]);

        // Children of tab: splits + tab-bound floats.
        var children: std.ArrayList(struct { kind: enum { split, float }, obj: std.json.ObjectMap }) = .empty;
        defer children.deinit(allocator);

        if (tab.get("splits")) |splits_val| {
            for (splits_val.array.items) |split_val| {
                children.append(allocator, .{ .kind = .split, .obj = split_val.object }) catch {};
            }
        }

        for (floats_arr) |float_val| {
            const float = float_val.object;
            if (float.get("parent_tab")) |pt| {
                if (pt == .integer and @as(usize, @intCast(pt.integer)) == ti) {
                    children.append(allocator, .{ .kind = .float, .obj = float }) catch {};
                }
            }
        }

        if (children.items.len > 0) {
            const next_indent = if (is_last_top) "   " else "│  ";
            var child_indent_buf: [256]u8 = undefined;
            const child_indent = std.fmt.bufPrint(&child_indent_buf, "{s}{s}", .{ indent, next_indent }) catch indent;

            for (children.items, 0..) |child, ci| {
                const is_last_child = (ci + 1 == children.items.len);
                const cbranch = if (is_last_child) "└" else "├";
                var lp_buf: [256]u8 = undefined;
                const lp = std.fmt.bufPrint(&lp_buf, "{s}{s}─ ", .{ child_indent, cbranch }) catch child_indent;

                const uuid = if (child.obj.get("uuid")) |u| u.string else "?";
                const uuid8 = uuid[0..@min(8, uuid.len)];
                const focused = if (child.obj.get("focused")) |f| f.bool else false;
                const sym = if (focused) ">" else " ";
                const pname = if (pane_name_map) |m| (m.get(uuid) orelse "-") else "-";

                switch (child.kind) {
                    .split => printTreeNode(lp, sym, ansi.SPLIT, "split", pname, uuid8),
                    .float => printTreeNode(lp, sym, ansi.FLOAT, "float", pname, uuid8),
                }
            }
        }

        top_index += 1;
    }

    // Global floats
    for (global_floats.items) |fi| {
        const float = floats_arr[fi].object;
        const uuid = if (float.get("uuid")) |u| u.string else "?";
        const uuid8 = uuid[0..@min(8, uuid.len)];
        const focused = if (float.get("focused")) |f| f.bool else false;
        const sym = if (focused) ">" else " ";
        const pname = if (pane_name_map) |m| (m.get(uuid) orelse "-") else "-";

        const is_last_top = (top_index + 1 == top_count);
        const branch = if (is_last_top) "└" else "├";
        var prefix_buf: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}{s}─ ", .{ indent, branch }) catch indent;
        printTreeNode(prefix, sym, ansi.FLOAT, "float", pname, uuid8);

        top_index += 1;
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

/// Ask the current mux to move focus in the given direction.
///
/// Intended for editor integration: Neovim tries wincmd first, and if it
/// cannot move, it calls this.
pub fn runFocusMove(allocator: std.mem.Allocator, dir: []const u8) !void {
    _ = allocator;

    const mux_socket = std.posix.getenv("HEXE_MUX_SOCKET") orelse {
        print("Error: not inside a hexe mux session (HEXE_MUX_SOCKET not set)\n", .{});
        return;
    };

    const dir_norm = std.mem.trim(u8, dir, " \t\n\r");
    if (!(std.mem.eql(u8, dir_norm, "left") or std.mem.eql(u8, dir_norm, "right") or std.mem.eql(u8, dir_norm, "up") or std.mem.eql(u8, dir_norm, "down"))) {
        print("Error: invalid dir (use left/right/up/down)\n", .{});
        return;
    }

    var client = ipc.Client.connect(mux_socket) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("mux is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"focus_move\",\"dir\":\"{s}\"}}", .{dir_norm}) catch return;
    conn.sendLine(msg) catch return;

    // Read and ignore response (best-effort).
    var resp_buf: [256]u8 = undefined;
    _ = conn.recvLine(&resp_buf) catch null;
}

/// Ask mux whether the current shell should be allowed to exit.
/// Intended to be called from shell keybindings (exit/Ctrl+D) so mux can
/// present a confirm dialog for the last split.
///
/// Exit codes: 0=allow, 1=deny
pub fn runExitIntent(allocator: std.mem.Allocator) !void {
    _ = allocator;

    const mux_socket = std.posix.getenv("HEXE_MUX_SOCKET") orelse {
        // Not in mux; allow.
        std.process.exit(0);
    };
    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        std.process.exit(0);
    };
    if (pane_uuid.len != 32) {
        std.process.exit(0);
    }

    var client = ipc.Client.connect(mux_socket) catch {
        // If mux is unreachable, don't trap the shell.
        std.process.exit(0);
    };
    defer client.close();

    var conn = client.toConnection();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "{{\"type\":\"exit_intent\",\"pane_uuid\":\"{s}\"}}", .{pane_uuid}) catch {
        std.process.exit(0);
    };
    conn.sendLine(msg) catch {
        std.process.exit(0);
    };

    // Wait for mux response (may block for popup confirm).
    var resp_buf: [256]u8 = undefined;
    const response = conn.recvLine(&resp_buf) catch {
        std.process.exit(0);
    };
    if (response == null) {
        std.process.exit(0);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response.?, .{}) catch {
        std.process.exit(0);
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("allow")) |allow_val| {
        if (allow_val == .bool and allow_val.bool) {
            std.process.exit(0);
        }
        std.process.exit(1);
    }

    // Unknown response -> allow.
    std.process.exit(0);
}

pub fn runShellEvent(
    allocator: std.mem.Allocator,
    cmd: []const u8,
    status: i64,
    duration_ms: i64,
    cwd: []const u8,
    jobs: i64,
    phase: []const u8,
    running: bool,
    started_at_ms: i64,
) !void {
    _ = allocator;

    const mux_socket = std.posix.getenv("HEXE_MUX_SOCKET") orelse {
        // Not in mux; ignore.
        return;
    };
    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        return;
    };
    if (pane_uuid.len != 32) return;

    var client = ipc.Client.connect(mux_socket) catch {
        // Don't break the shell.
        return;
    };
    defer client.close();
    var conn = client.toConnection();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    var w = buf.writer(std.heap.page_allocator);

    try w.writeAll("{\"type\":\"shell_event\",\"pane_uuid\":\"");
    try w.writeAll(pane_uuid);
    try w.writeAll("\"");

    if (cmd.len > 0) {
        try w.writeAll(",\"cmd\":\"");
        try writeJsonEscaped(w, cmd);
        try w.writeAll("\"");
    }
    if (cwd.len > 0) {
        try w.writeAll(",\"cwd\":\"");
        try writeJsonEscaped(w, cwd);
        try w.writeAll("\"");
    }
    if (phase.len > 0) {
        try w.writeAll(",\"phase\":\"");
        try writeJsonEscaped(w, phase);
        try w.writeAll("\"");
    }
    if (running) {
        try w.writeAll(",\"running\":true");
    }
    if (started_at_ms > 0) {
        try w.print(",\"started_at_ms\":{d}", .{started_at_ms});
    }

    // End-of-command metadata
    try w.print(",\"status\":{d}", .{status});
    try w.print(",\"duration_ms\":{d}", .{duration_ms});
    try w.print(",\"jobs\":{d}", .{jobs});
    try w.writeAll("}");

    conn.sendLine(buf.items) catch return;

    // Best-effort, ignore response.
    var resp_buf: [128]u8 = undefined;
    _ = conn.recvLine(&resp_buf) catch null;
}

fn writeJsonEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}
