const std = @import("std");
const core = @import("core");
const ipc = core.ipc;

pub const runMuxFloat = @import("mux_float.zig").runMuxFloat;
pub const runPodList = @import("pod_list.zig").runPodList;
pub const runPodSend = @import("pod_send.zig").runPodSend;
pub const runPodNew = @import("pod_new.zig").runPodNew;
pub const runPodAttach = @import("pod_attach.zig").runPodAttach;
pub const runPodKill = @import("pod_kill.zig").runPodKill;
pub const runPodGc = @import("pod_gc.zig").runPodGc;

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
    const wire = core.wire;
    const posix = std.posix;

    const inst = posix.getenv("HEXE_INSTANCE");
    if (inst) |name| {
        if (name.len > 0) {
            print("Instance: {s}\n", .{name});
        } else {
            print("Instance: default\n", .{});
        }
    } else {
        print("Instance: default\n", .{});
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    // Send status request with full_mode flag
    const flag: [1]u8 = .{if (details) @as(u8, 1) else @as(u8, 0)};
    wire.writeControl(fd, .status, &flag) catch return;

    // Read response
    const hdr = wire.readControlHeader(fd) catch return;
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type != .status or hdr.payload_len < @sizeOf(wire.StatusResp)) {
        print("Invalid response from daemon\n", .{});
        return;
    }

    // Read the entire payload into a buffer
    const payload = allocator.alloc(u8, hdr.payload_len) catch {
        print("Allocation failed\n", .{});
        return;
    };
    defer allocator.free(payload);
    wire.readExact(fd, payload) catch return;

    var off: usize = 0;

    // Parse StatusResp header
    if (off + @sizeOf(wire.StatusResp) > payload.len) return;
    const status_hdr = std.mem.bytesToValue(wire.StatusResp, payload[off..][0..@sizeOf(wire.StatusResp)]);
    off += @sizeOf(wire.StatusResp);

    // Connected clients
    if (status_hdr.client_count > 0) {
        print("Connected muxes: {d}\n", .{status_hdr.client_count});
    }

    var ci: u16 = 0;
    while (ci < status_hdr.client_count) : (ci += 1) {
        if (off + @sizeOf(wire.StatusClient) > payload.len) return;
        const sc = std.mem.bytesToValue(wire.StatusClient, payload[off..][0..@sizeOf(wire.StatusClient)]);
        off += @sizeOf(wire.StatusClient);

        // Read trailing: name, mux_state
        if (off + sc.name_len > payload.len) return;
        const name_str = if (sc.name_len > 0) payload[off .. off + sc.name_len] else "unknown";
        off += sc.name_len;

        if (off + sc.mux_state_len > payload.len) return;
        const mux_state = if (sc.mux_state_len > 0) payload[off .. off + sc.mux_state_len] else "";
        off += sc.mux_state_len;

        const is_last_client = (ci + 1 == status_hdr.client_count);
        const branch = if (is_last_client) "\xe2\x94\x94" else "\xe2\x94\x9c";
        const child_prefix = if (is_last_client) "   " else "\xe2\x94\x82  ";

        const sid8: []const u8 = if (sc.has_session_id != 0) sc.session_id[0..8] else "????????";

        var mux_line: [256]u8 = undefined;
        const prefix = std.fmt.bufPrint(&mux_line, "{s}\xe2\x94\x80 ", .{branch}) catch "";
        printTreeNode(prefix, " ", ansi.MUX, "mux", name_str, sid8);

        // Read pane entries and build name map
        var pane_names = std.StringHashMap([]const u8).init(allocator);
        defer pane_names.deinit();

        var pi: u16 = 0;
        while (pi < sc.pane_count) : (pi += 1) {
            if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) return;
            const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
            off += @sizeOf(wire.StatusPaneEntry);

            if (off + pe.name_len > payload.len) return;
            const pname = if (pe.name_len > 0) payload[off .. off + pe.name_len] else "";
            off += pe.name_len;
            if (off + pe.sticky_pwd_len > payload.len) return;
            off += pe.sticky_pwd_len; // skip sticky_pwd

            if (pname.len > 0) {
                pane_names.put(&pe.uuid, pname) catch {};
            }
        }

        if (mux_state.len > 0) {
            printMuxTree(allocator, mux_state, child_prefix, &pane_names);
        }
    }

    // Detached sessions
    if (status_hdr.detached_count > 0) {
        print("\nDetached sessions: {d}\n", .{status_hdr.detached_count});
    }

    var di: u16 = 0;
    while (di < status_hdr.detached_count) : (di += 1) {
        if (off + @sizeOf(wire.DetachedSessionEntry) > payload.len) return;
        const de = std.mem.bytesToValue(wire.DetachedSessionEntry, payload[off..][0..@sizeOf(wire.DetachedSessionEntry)]);
        off += @sizeOf(wire.DetachedSessionEntry);

        if (off + de.name_len > payload.len) return;
        const name_str = if (de.name_len > 0) payload[off .. off + de.name_len] else "unknown";
        off += de.name_len;

        if (off + de.mux_state_len > payload.len) return;
        const mux_state = if (de.mux_state_len > 0) payload[off .. off + de.mux_state_len] else "";
        off += de.mux_state_len;

        print("  {s} [{s}] {d} panes - reattach: hexe mux attach {s}\n", .{ name_str, de.session_id[0..8], de.pane_count, name_str });

        if (mux_state.len > 0) {
            printMuxTree(allocator, mux_state, "    ", null);
        }
    }

    // Orphaned panes
    if (status_hdr.orphaned_count > 0) {
        print("\nOrphaned panes: {d}\n", .{status_hdr.orphaned_count});
    }

    var oi: u16 = 0;
    while (oi < status_hdr.orphaned_count) : (oi += 1) {
        if (off + @sizeOf(wire.StatusPaneEntry) > payload.len) return;
        const pe = std.mem.bytesToValue(wire.StatusPaneEntry, payload[off..][0..@sizeOf(wire.StatusPaneEntry)]);
        off += @sizeOf(wire.StatusPaneEntry);

        if (off + pe.name_len > payload.len) return;
        const pname = if (pe.name_len > 0) payload[off .. off + pe.name_len] else "";
        off += pe.name_len;
        if (off + pe.sticky_pwd_len > payload.len) return;
        off += pe.sticky_pwd_len;

        if (pname.len > 0) {
            print("  [{s}] {s} pid={d}\n", .{ pe.uuid[0..8], pname, pe.pid });
        } else {
            print("  [{s}] pid={d}\n", .{ pe.uuid[0..8], pe.pid });
        }
    }

    // Sticky panes
    if (status_hdr.sticky_count > 0) {
        print("\nSticky panes: {d}\n", .{status_hdr.sticky_count});
    }

    var si: u16 = 0;
    while (si < status_hdr.sticky_count) : (si += 1) {
        if (off + @sizeOf(wire.StickyPaneEntry) > payload.len) return;
        const se = std.mem.bytesToValue(wire.StickyPaneEntry, payload[off..][0..@sizeOf(wire.StickyPaneEntry)]);
        off += @sizeOf(wire.StickyPaneEntry);

        if (off + se.name_len > payload.len) return;
        off += se.name_len; // skip name (not displayed for sticky currently)

        if (off + se.pwd_len > payload.len) return;
        const pwd = if (se.pwd_len > 0) payload[off .. off + se.pwd_len] else "";
        off += se.pwd_len;

        print("  [{s}] pid={d}", .{ se.uuid[0..8], se.pid });
        if (pwd.len > 0) {
            print(" pwd={s}", .{pwd});
        }
        if (se.key != 0) {
            print(" key={c}", .{se.key});
        }
        print("\n", .{});
    }
}

pub fn runInfo(allocator: std.mem.Allocator, uuid_arg: []const u8, show_creator: bool, show_last: bool) !void {
    const wire = core.wire;
    const posix = std.posix;

    var target_uuid: [32]u8 = undefined;

    if (uuid_arg.len > 0) {
        if (uuid_arg.len >= 32) {
            @memcpy(&target_uuid, uuid_arg[0..32]);
        } else {
            print("Invalid UUID\n", .{});
            return;
        }
    } else if (show_creator or show_last) {
        if (resolveRelatedPane(allocator, show_creator)) |resolved| {
            target_uuid = resolved;
        } else return;
    } else {
        const env_uuid = posix.getenv("HEXE_PANE_UUID") orelse {
            print("Not inside a hexe mux session (use --uuid to query specific pane)\n", .{});
            return;
        };
        if (env_uuid.len >= 32) {
            @memcpy(&target_uuid, env_uuid[0..32]);
        } else {
            print("Invalid HEXE_PANE_UUID\n", .{});
            return;
        }
    }

    // Query SES for pane info via binary protocol
    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    var pu: wire.PaneUuid = undefined;
    pu.uuid = target_uuid;
    wire.writeControl(fd, .pane_info, std.mem.asBytes(&pu)) catch return;

    // Read response
    const hdr = wire.readControlHeader(fd) catch return;
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .pane_not_found) {
        print("Pane not found\n", .{});
        return;
    }
    if (msg_type != .pane_info or hdr.payload_len < @sizeOf(wire.PaneInfoResp)) {
        print("Invalid response from daemon\n", .{});
        return;
    }

    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch return;

    // Read trailing data
    const trail_len = hdr.payload_len - @sizeOf(wire.PaneInfoResp);
    var trail_buf: [8192]u8 = undefined;
    if (trail_len > trail_buf.len) return;
    if (trail_len > 0) {
        wire.readExact(fd, trail_buf[0..trail_len]) catch return;
    }

    // Parse trailing data in order: name, fg, cwd, tty, socket, session_name, layout, last_cmd, base_process, sticky_pwd
    var off: usize = 0;
    const name = trail_buf[off .. off + resp.name_len];
    off += resp.name_len;
    const fg_process = trail_buf[off .. off + resp.fg_len];
    off += resp.fg_len;
    const cwd_str = trail_buf[off .. off + resp.cwd_len];
    off += resp.cwd_len;
    const tty_str = trail_buf[off .. off + resp.tty_len];
    off += resp.tty_len;
    const socket_path = trail_buf[off .. off + resp.socket_path_len];
    off += resp.socket_path_len;
    const session_name = trail_buf[off .. off + resp.session_name_len];
    off += resp.session_name_len;
    const layout_path = trail_buf[off .. off + resp.layout_path_len];
    off += resp.layout_path_len;
    const last_cmd = trail_buf[off .. off + resp.last_cmd_len];
    off += resp.last_cmd_len;
    const base_process = trail_buf[off .. off + resp.base_process_len];
    off += resp.base_process_len;
    _ = trail_buf[off .. off + resp.sticky_pwd_len]; // sticky_pwd (not displayed currently)

    // Display
    print("Pane Info:\n", .{});
    print("  UUID: {s}\n", .{&target_uuid});
    print("  Shell PID: {d}\n", .{resp.pid});

    if (resp.base_process_len > 0) {
        print("  Base Process: {s} (pid={d})\n", .{ base_process, resp.base_pid });
    }
    if (resp.fg_len > 0) {
        print("  Active Process: {s} (pid={d})\n", .{ fg_process, resp.fg_pid });
    }
    if (resp.cwd_len > 0) {
        print("  CWD: {s}\n", .{cwd_str});
    }
    if (resp.name_len > 0) {
        print("  Name: {s}\n", .{name});
    }
    if (resp.tty_len > 0) {
        print("  TTY: {s}\n", .{tty_str});
    }
    if (resp.cols > 0 and resp.rows > 0) {
        print("  Window: {d}x{d}\n", .{ resp.cols, resp.rows });
    }
    if (resp.session_name_len > 0) {
        print("  Session: {s}\n", .{session_name});
    }
    if (resp.has_created_from != 0) {
        print("  Creator: {s}\n", .{resp.created_from[0..8]});
    }
    if (resp.has_focused_from != 0) {
        print("  Last: {s}\n", .{resp.focused_from[0..8]});
    }
    if (resp.layout_path_len > 0) {
        print("  Layout: {s}\n", .{layout_path});
    }
    if (resp.socket_path_len > 0) {
        print("  Socket: {s}\n", .{socket_path});
    }
    print("  Focused: {}\n", .{resp.is_focused != 0});
    const pane_type_str: []const u8 = if (resp.pane_type == 1) "float" else "split";
    print("  Type: {s}\n", .{pane_type_str});
    print("  Cursor: {d},{d}\n", .{ resp.cursor_x, resp.cursor_y });
    print("  Cursor Style: {d}\n", .{resp.cursor_style});
    print("  Cursor Visible: {}\n", .{resp.cursor_visible != 0});
    print("  Alt Screen: {}\n", .{resp.alt_screen != 0});

    if (resp.last_cmd_len > 0) {
        print("  Last Cmd: {s}\n", .{last_cmd});
    }
    if (resp.has_last_status != 0) {
        print("  Last Status: {d}\n", .{resp.last_status});
    }
    if (resp.has_last_duration != 0) {
        print("  Last Duration: {d}ms\n", .{resp.last_duration_ms});
    }
    if (resp.has_last_jobs != 0) {
        print("  Last Jobs: {d}\n", .{resp.last_jobs});
    }
}

pub fn runNotify(allocator: std.mem.Allocator, uuid: []const u8, creator: bool, last: bool, broadcast: bool, message: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    var target_uuid: [32]u8 = undefined;
    var has_target = false;

    if (uuid.len > 0) {
        if (uuid.len >= 32) {
            @memcpy(&target_uuid, uuid[0..32]);
            has_target = true;
        }
    } else if (creator or last) {
        if (resolveRelatedPane(allocator, creator)) |resolved| {
            target_uuid = resolved;
            has_target = true;
        } else return;
    } else if (!broadcast) {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: no target (use --uuid, --creator, --last, --broadcast, or run inside mux)\n", .{});
            return;
        };
        if (env_uuid.len >= 32) {
            @memcpy(&target_uuid, env_uuid[0..32]);
            has_target = true;
        }
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    if (has_target) {
        const tn = wire.TargetedNotify{
            .uuid = target_uuid,
            .timeout_ms = 0,
            .msg_len = @intCast(message.len),
        };
        wire.writeControlWithTrail(fd, .targeted_notify, std.mem.asBytes(&tn), message) catch {};
    } else {
        const n = wire.Notify{ .msg_len = @intCast(message.len) };
        wire.writeControlWithTrail(fd, .broadcast_notify, std.mem.asBytes(&n), message) catch {};
    }
}

// ─── Binary CLI helpers ────────────────────────────────────────────────────

/// Connect to SES with CLI handshake byte. Returns fd on success.
pub fn connectSesCliChannel(allocator: std.mem.Allocator) ?std.posix.fd_t {
    const wire = core.wire;
    const socket_path = ipc.getSesSocketPath(allocator) catch return null;
    defer allocator.free(socket_path);
    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
        }
        return null;
    };
    const fd = client.fd;
    const handshake: [1]u8 = .{wire.SES_HANDSHAKE_CLI};
    wire.writeAll(fd, &handshake) catch {
        client.close();
        return null;
    };
    return fd;
}

/// Query SES for a pane's created_from or focused_from UUID.
/// If `want_creator` is true, returns created_from; otherwise focused_from.
fn resolveRelatedPane(allocator: std.mem.Allocator, want_creator: bool) ?[32]u8 {
    const wire = core.wire;
    const posix = std.posix;

    const current_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        print("Error: --creator/--last requires running inside hexe mux\n", .{});
        return null;
    };
    if (current_uuid.len < 32) return null;

    const fd = connectSesCliChannel(allocator) orelse return null;
    defer posix.close(fd);

    var pu: wire.PaneUuid = undefined;
    @memcpy(&pu.uuid, current_uuid[0..32]);
    wire.writeControl(fd, .pane_info, std.mem.asBytes(&pu)) catch return null;

    const hdr = wire.readControlHeader(fd) catch return null;
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .pane_not_found) {
        print("Error: pane not found\n", .{});
        return null;
    }
    if (msg_type != .pane_info) return null;
    if (hdr.payload_len < @sizeOf(wire.PaneInfoResp)) return null;

    const resp = wire.readStruct(wire.PaneInfoResp, fd) catch return null;
    if (want_creator) {
        if (resp.has_created_from != 0) return resp.created_from;
        print("Error: current pane has no creator\n", .{});
        return null;
    } else {
        if (resp.has_focused_from != 0) return resp.focused_from;
        print("Error: current pane has no previous focus\n", .{});
        return null;
    }
}

// ─── End binary CLI helpers ────────────────────────────────────────────────


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
    const wire = core.wire;
    const posix = std.posix;

    // Build the data to send.
    var data_buf: [4096]u8 = undefined;
    var data_len: usize = 0;

    if (ctrl.len > 0) {
        if (ctrl.len == 1 and ctrl[0] >= 'a' and ctrl[0] <= 'z') {
            data_buf[0] = ctrl[0] - 'a' + 1;
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

    if (enter and data_len < data_buf.len) {
        data_buf[data_len] = '\n';
        data_len += 1;
    }

    if (data_len == 0) {
        print("Error: no data to send (use text argument, --ctrl, or --enter)\n", .{});
        return;
    }

    var target_uuid: [32]u8 = .{0} ** 32;

    if (uuid.len > 0) {
        if (uuid.len >= 32) @memcpy(&target_uuid, uuid[0..32]);
    } else if (creator or last) {
        if (resolveRelatedPane(allocator, creator)) |resolved| {
            target_uuid = resolved;
        } else return;
    } else if (broadcast) {
        // All-zeros UUID = broadcast.
    } else {
        const env_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
            print("Error: no target specified (use --uuid, --creator, --last, --broadcast, or run inside mux)\n", .{});
            return;
        };
        if (env_uuid.len >= 32) @memcpy(&target_uuid, env_uuid[0..32]);
    }

    const fd = connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    const sk = wire.SendKeys{
        .uuid = target_uuid,
        .data_len = @intCast(data_len),
    };
    wire.writeControlWithTrail(fd, .send_keys, std.mem.asBytes(&sk), data_buf[0..data_len]) catch {};
}

/// Ask the current mux to move focus in the given direction.
///
/// Intended for editor integration: Neovim tries wincmd first, and if it
/// cannot move, it calls this.
pub fn runFocusMove(allocator: std.mem.Allocator, dir: []const u8) !void {
    const wire = core.wire;
    const posix = std.posix;

    const dir_norm = std.mem.trim(u8, dir, " \t\n\r");
    const dir_byte: u8 = if (std.mem.eql(u8, dir_norm, "left"))
        0
    else if (std.mem.eql(u8, dir_norm, "right"))
        1
    else if (std.mem.eql(u8, dir_norm, "up"))
        2
    else if (std.mem.eql(u8, dir_norm, "down"))
        3
    else {
        print("Error: invalid dir (use left/right/up/down)\n", .{});
        return;
    };

    const ses_path = ipc.getSesSocketPath(allocator) catch {
        print("Error: cannot determine ses socket path\n", .{});
        return;
    };
    defer allocator.free(ses_path);

    var client = ipc.Client.connect(ses_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();
    const fd = client.fd;

    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse return;
    if (pane_uuid.len != 32) return;

    // Send CLI handshake byte.
    _ = posix.write(fd, &.{wire.SES_HANDSHAKE_CLI}) catch return;

    // Send focus_move message.
    var fm: wire.FocusMove = undefined;
    @memcpy(&fm.uuid, pane_uuid[0..32]);
    fm.dir = dir_byte;
    wire.writeControl(fd, .focus_move, std.mem.asBytes(&fm)) catch return;
}

/// Ask mux whether the current shell should be allowed to exit.
/// Intended to be called from shell keybindings (exit/Ctrl+D) so mux can
/// present a confirm dialog for the last split.
///
/// Exit codes: 0=allow, 1=deny
pub fn runExitIntent(allocator: std.mem.Allocator) !void {
    const wire = core.wire;
    const posix = std.posix;

    const pane_uuid = std.posix.getenv("HEXE_PANE_UUID") orelse {
        std.process.exit(0);
    };
    if (pane_uuid.len != 32) {
        std.process.exit(0);
    }

    const ses_path = ipc.getSesSocketPath(allocator) catch {
        std.process.exit(0);
    };
    defer allocator.free(ses_path);

    var client = ipc.Client.connect(ses_path) catch {
        // If ses is unreachable, don't trap the shell.
        std.process.exit(0);
    };
    defer client.close();
    const fd = client.fd;

    // Send CLI handshake byte.
    _ = posix.write(fd, &.{wire.SES_HANDSHAKE_CLI}) catch {
        std.process.exit(0);
    };

    // Send exit_intent message.
    var ei: wire.ExitIntent = undefined;
    @memcpy(&ei.uuid, pane_uuid[0..32]);
    wire.writeControl(fd, .exit_intent, std.mem.asBytes(&ei)) catch {
        std.process.exit(0);
    };

    // Wait for exit_intent_result (may block for popup confirm).
    const hdr = wire.readControlHeader(fd) catch {
        std.process.exit(0);
    };
    if (@as(wire.MsgType, @enumFromInt(hdr.msg_type)) != .exit_intent_result) {
        std.process.exit(0);
    }
    const result = wire.readStruct(wire.ExitIntentResult, fd) catch {
        std.process.exit(0);
    };

    if (result.allow != 0) {
        std.process.exit(0);
    }
    std.process.exit(1);
}

pub fn runShellEvent(
    cmd: []const u8,
    status: i64,
    duration_ms: i64,
    cwd: []const u8,
    jobs: i64,
    phase: []const u8,
    running: bool,
    started_at_ms: i64,
) !void {
    const pod_socket = std.posix.getenv("HEXE_POD_SOCKET") orelse return;

    const wire = core.wire;
    const posix = std.posix;

    var client = ipc.Client.connect(pod_socket) catch return;
    defer client.close();
    const fd = client.fd;

    // Send SHP handshake byte.
    _ = posix.write(fd, &.{wire.POD_HANDSHAKE_SHP_CTL}) catch return;

    // Build ShpShellEvent struct.
    const phase_byte: u8 = if (std.mem.eql(u8, phase, "start")) 1 else 0;
    const evt = wire.ShpShellEvent{
        .phase = phase_byte,
        .status = @intCast(status),
        .duration_ms = duration_ms,
        .started_at = started_at_ms,
        .jobs = @intCast(jobs),
        .running = @intFromBool(running),
        .cmd_len = @intCast(cmd.len),
        .cwd_len = @intCast(cwd.len),
    };

    // Send as binary control message with trailing cmd + cwd.
    wire.writeControlMsg(fd, .shp_shell_event, std.mem.asBytes(&evt), &.{ cmd, cwd }) catch return;
}

