const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const pod_meta = core.pod_meta;

const print = std.debug.print;

pub const PodRecord = struct {
    uuid: [32]u8,
    name: []const u8,
    pid: i64,
    child_pid: i64,
    cwd: []const u8,
    isolated: bool,
    labels: []const []const u8,
    created_at: i64,
    alive: ?bool = null,
};

pub fn runPodList(allocator: std.mem.Allocator, where_lua: []const u8, probe: bool, alive_only: bool) !void {
    const dir = try ipc.getSocketDir(allocator);
    defer allocator.free(dir);

    var records = std.ArrayList(PodRecord).empty;
    defer {
        for (records.items) |r| {
            allocator.free(r.name);
            allocator.free(r.cwd);
            for (r.labels) |lab| allocator.free(lab);
            allocator.free(r.labels);
        }
        records.deinit(allocator);
    }

    try scanMetaFiles(allocator, dir, &records);

    if (probe) {
        probeSockets(allocator, &records, alive_only);
    }

    if (where_lua.len > 0) {
        try filterWithLua(allocator, where_lua, &records);
    }

    // Output: one line per pod, stable + grep-friendly.
    for (records.items) |r| {
        print(
            "{s} uuid={s} name={s} pid={d} child_pid={d} cwd={s} isolated={d}",
            .{ pod_meta.POD_META_PREFIX, r.uuid[0..], r.name, r.pid, r.child_pid, r.cwd, if (r.isolated) @as(u8, 1) else 0 },
        );

        if (r.alive) |a| {
            print(" alive={d}", .{if (a) @as(u8, 1) else 0});
        }

        print(" labels=", .{});
        for (r.labels, 0..) |lab, i| {
            if (i > 0) print(",", .{});
            print("{s}", .{lab});
        }
        print(" created_at={d}\n", .{r.created_at});
    }
}

fn probeSockets(allocator: std.mem.Allocator, records: *std.ArrayList(PodRecord), alive_only: bool) void {
    var i: usize = 0;
    while (i < records.items.len) {
        const sock = ipc.getPodSocketPath(allocator, &records.items[i].uuid) catch {
            i += 1;
            continue;
        };
        defer allocator.free(sock);
        const maybe = ipc.Client.connect(sock) catch null;
        if (maybe != null) {
            var c = maybe.?;
            c.close();
            records.items[i].alive = true;
            i += 1;
        } else if (alive_only) {
            const rec = records.orderedRemove(i);
            freeRecord(allocator, rec);
        } else {
            records.items[i].alive = false;
            i += 1;
        }
    }
}

fn scanMetaFiles(allocator: std.mem.Allocator, socket_dir: []const u8, out: *std.ArrayList(PodRecord)) !void {
    var dir = try std.fs.cwd().openDir(socket_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "pod-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;

        var f = dir.openFile(entry.name, .{}) catch continue;
        defer f.close();

        var buf: [4096]u8 = undefined;
        const n = try f.readAll(&buf);
        if (n == 0) continue;
        const line_raw = std.mem.trim(u8, buf[0..n], " \t\n\r");
        if (!std.mem.startsWith(u8, line_raw, pod_meta.POD_META_PREFIX)) continue;

        const rec = parseMetaLine(allocator, line_raw) catch continue;
        // Basic sanity.
        if (rec.uuid.len != 32) {
            freeRecord(allocator, rec);
            continue;
        }
        try out.append(allocator, rec);
    }
}

fn freeRecord(allocator: std.mem.Allocator, rec: PodRecord) void {
    allocator.free(rec.name);
    allocator.free(rec.cwd);
    for (rec.labels) |lab| allocator.free(lab);
    allocator.free(rec.labels);
}

fn parseMetaLine(allocator: std.mem.Allocator, line: []const u8) !PodRecord {
    // Format: HEXE_POD k=v k=v ... (single line)
    var uuid: [32]u8 = undefined;
    var name: []const u8 = "";
    var pid: i64 = 0;
    var child_pid: i64 = 0;
    var cwd: []const u8 = "";
    var isolated: bool = false;
    var created_at: i64 = 0;
    var labels_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (labels_list.items) |lab| allocator.free(lab);
        labels_list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next(); // prefix
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const val = part[eq + 1 ..];

        if (std.mem.eql(u8, key, "uuid")) {
            if (val.len == 32) @memcpy(&uuid, val[0..32]);
        } else if (std.mem.eql(u8, key, "name")) {
            name = val;
        } else if (std.mem.eql(u8, key, "pid")) {
            pid = std.fmt.parseInt(i64, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "child_pid")) {
            child_pid = std.fmt.parseInt(i64, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "cwd")) {
            cwd = val;
        } else if (std.mem.eql(u8, key, "isolated")) {
            isolated = std.mem.eql(u8, val, "1");
        } else if (std.mem.eql(u8, key, "created_at")) {
            created_at = std.fmt.parseInt(i64, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "labels")) {
            var lit = std.mem.splitScalar(u8, val, ',');
            while (lit.next()) |l| {
                const t = std.mem.trim(u8, l, " \t\n\r");
                if (t.len == 0) continue;
                try labels_list.append(allocator, try allocator.dupe(u8, t));
            }
        }
    }

    const owned_name = try allocator.dupe(u8, if (name.len > 0) name else "-");
    errdefer allocator.free(owned_name);
    const owned_cwd = try allocator.dupe(u8, if (cwd.len > 0) cwd else "-");
    errdefer allocator.free(owned_cwd);
    const labels = try labels_list.toOwnedSlice(allocator);

    return .{
        .uuid = uuid,
        .name = owned_name,
        .pid = pid,
        .child_pid = child_pid,
        .cwd = owned_cwd,
        .isolated = isolated,
        .labels = labels,
        .created_at = created_at,
    };
}

fn filterWithLua(allocator: std.mem.Allocator, where_lua: []const u8, records: *std.ArrayList(PodRecord)) !void {
    var rt = try core.LuaRuntime.init(allocator);
    defer rt.deinit();

    // Compile predicate once as function: return function(pod) <user> end
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(allocator);
    try chunk.appendSlice(allocator, "return function(pod)\n");
    try chunk.appendSlice(allocator, where_lua);
    try chunk.appendSlice(allocator, "\nend\n");

    const code_z = try rt.allocator.dupeZ(u8, chunk.items);
    defer rt.allocator.free(code_z);

    rt.lua.loadString(code_z) catch {
        // On syntax error, treat as no matches.
        records.clearRetainingCapacity();
        return;
    };
    rt.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        rt.lua.pop(1);
        records.clearRetainingCapacity();
        return;
    };
    // Stack: [predicate_fn]

    var i: usize = 0;
    while (i < records.items.len) {
        const keep = evalPredicate(&rt, records.items[i]) catch false;
        if (!keep) {
            const rec = records.orderedRemove(i);
            freeRecord(allocator, rec);
        } else {
            i += 1;
        }
    }

    // Pop predicate_fn
    rt.lua.pop(1);
}

fn evalPredicate(rt: *core.LuaRuntime, rec: PodRecord) !bool {
    // Duplicate predicate fn and call it with pod table.
    rt.lua.pushValue(-1);
    pushPodTable(rt, rec);
    rt.lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
        rt.lua.pop(1);
        return false;
    };
    defer rt.lua.pop(1);
    const ok = if (rt.lua.typeOf(-1) == .boolean) rt.lua.toBoolean(-1) else false;
    return ok;
}

fn pushPodTable(rt: *core.LuaRuntime, rec: PodRecord) void {
    rt.lua.createTable(0, 8);

    _ = rt.lua.pushString("uuid");
    _ = rt.lua.pushString(rec.uuid[0..]);
    rt.lua.setTable(-3);

    _ = rt.lua.pushString("name");
    _ = rt.lua.pushString(rec.name);
    rt.lua.setTable(-3);

    _ = rt.lua.pushString("pid");
    rt.lua.pushInteger(rec.pid);
    rt.lua.setTable(-3);

    _ = rt.lua.pushString("child_pid");
    rt.lua.pushInteger(rec.child_pid);
    rt.lua.setTable(-3);

    _ = rt.lua.pushString("cwd");
    _ = rt.lua.pushString(rec.cwd);
    rt.lua.setTable(-3);

    _ = rt.lua.pushString("isolated");
    rt.lua.pushBoolean(rec.isolated);
    rt.lua.setTable(-3);

    _ = rt.lua.pushString("created_at");
    rt.lua.pushInteger(rec.created_at);
    rt.lua.setTable(-3);

    if (rec.alive) |a| {
        _ = rt.lua.pushString("alive");
        rt.lua.pushBoolean(a);
        rt.lua.setTable(-3);
    }

    _ = rt.lua.pushString("labels");
    rt.lua.createTable(@intCast(rec.labels.len), 0);
    for (rec.labels, 0..) |lab, idx| {
        _ = rt.lua.pushString(lab);
        rt.lua.rawSetIndex(-2, @intCast(idx + 1));
    }
    rt.lua.setTable(-3);
}
