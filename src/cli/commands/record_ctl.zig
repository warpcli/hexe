const std = @import("std");

const print = std.debug.print;

const Scope = enum { pod };

const RecordState = struct {
    pid: i32 = 0,
    scope: Scope = .pod,
    uuid: []const u8 = "",
    name: []const u8 = "",
    socket: []const u8 = "",
    out: []const u8 = "",
    capture_input: bool = false,
    started_ms: i64 = 0,
};

pub fn runRecordStart(
    allocator: std.mem.Allocator,
    scope_raw: []const u8,
    uuid: []const u8,
    name: []const u8,
    socket: []const u8,
    out: []const u8,
    capture_input: bool,
) !void {
    const scope = parseScope(scope_raw) orelse {
        print("Error: unsupported scope '{s}' (supported: pod)\n", .{scope_raw});
        return;
    };

    const state_path = try getStatePath(allocator, scope);
    defer allocator.free(state_path);

    if (try loadState(allocator, state_path)) |st| {
        defer freeState(allocator, st);
        if (isPidAlive(st.pid)) {
            print("already recording (pid={d})\n", .{st.pid});
            return;
        }
        std.fs.cwd().deleteFile(state_path) catch {};
    }

    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);

    const out_final = if (out.len > 0) out else "/tmp/hexe-pod.cast";

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    try argv.append(allocator, "pod");
    try argv.append(allocator, "record");
    if (uuid.len > 0) {
        try argv.append(allocator, "--uuid");
        try argv.append(allocator, uuid);
    } else if (name.len > 0) {
        try argv.append(allocator, "--name");
        try argv.append(allocator, name);
    } else if (socket.len > 0) {
        try argv.append(allocator, "--socket");
        try argv.append(allocator, socket);
    }
    try argv.append(allocator, "--out");
    try argv.append(allocator, out_final);
    if (capture_input) try argv.append(allocator, "--capture-input");

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const pid: i32 = @intCast(child.id);
    const state = RecordState{
        .pid = pid,
        .scope = scope,
        .uuid = uuid,
        .name = name,
        .socket = socket,
        .out = out_final,
        .capture_input = capture_input,
        .started_ms = std.time.milliTimestamp(),
    };
    try saveState(allocator, state_path, state);
    print("recording started pid={d} out={s}\n", .{ pid, out_final });
}

pub fn runRecordStop(allocator: std.mem.Allocator, scope_raw: []const u8) !void {
    const scope = parseScope(scope_raw) orelse {
        print("Error: unsupported scope '{s}' (supported: pod)\n", .{scope_raw});
        return;
    };
    const state_path = try getStatePath(allocator, scope);
    defer allocator.free(state_path);

    const st = (try loadState(allocator, state_path)) orelse {
        print("not recording\n", .{});
        return;
    };
    defer freeState(allocator, st);

    if (st.pid > 0 and isPidAlive(st.pid)) {
        _ = std.c.kill(st.pid, std.c.SIG.TERM);
    }
    std.fs.cwd().deleteFile(state_path) catch {};
    print("recording stopped\n", .{});
}

pub fn runRecordStatus(allocator: std.mem.Allocator, scope_raw: []const u8, json: bool) !void {
    const scope = parseScope(scope_raw) orelse {
        print("0\n", .{});
        return;
    };
    const state_path = try getStatePath(allocator, scope);
    defer allocator.free(state_path);

    const st_opt = try loadState(allocator, state_path);
    if (st_opt == null) {
        if (json) {
            print("{{\"active\":false}}\n", .{});
        } else {
            print("0\n", .{});
        }
        return;
    }
    const st = st_opt.?;
    defer freeState(allocator, st);

    const active = st.pid > 0 and isPidAlive(st.pid);
    if (!active) {
        std.fs.cwd().deleteFile(state_path) catch {};
        if (json) {
            print("{{\"active\":false}}\n", .{});
        } else {
            print("0\n", .{});
        }
        return;
    }

    if (json) {
        print("{{\"active\":true,\"pid\":{d},\"scope\":\"pod\",\"out\":\"{s}\",\"started_ms\":{d}}}\n", .{ st.pid, st.out, st.started_ms });
    } else {
        print("1\n", .{});
    }
}

pub fn runRecordToggle(
    allocator: std.mem.Allocator,
    scope_raw: []const u8,
    uuid: []const u8,
    name: []const u8,
    socket: []const u8,
    out: []const u8,
    capture_input: bool,
) !void {
    const scope = parseScope(scope_raw) orelse {
        print("Error: unsupported scope '{s}' (supported: pod)\n", .{scope_raw});
        return;
    };
    const state_path = try getStatePath(allocator, scope);
    defer allocator.free(state_path);

    if (try loadState(allocator, state_path)) |st| {
        defer freeState(allocator, st);
        if (isPidAlive(st.pid)) {
            try runRecordStop(allocator, scope_raw);
            return;
        }
        std.fs.cwd().deleteFile(state_path) catch {};
    }
    try runRecordStart(allocator, scope_raw, uuid, name, socket, out, capture_input);
}

fn parseScope(scope_raw: []const u8) ?Scope {
    if (scope_raw.len == 0 or std.mem.eql(u8, scope_raw, "pod")) return .pod;
    return null;
}

fn isPidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    const rc = std.c.kill(pid, 0);
    return rc == 0;
}

fn getStatePath(allocator: std.mem.Allocator, scope: Scope) ![]u8 {
    const inst = std.posix.getenv("HEXE_INSTANCE") orelse "default";
    var safe_buf: [64]u8 = undefined;
    const safe = sanitizeInstance(safe_buf[0..], inst);
    const dir = try std.fmt.allocPrint(allocator, "/tmp/hexe/{s}", .{safe});
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    return std.fmt.allocPrint(allocator, "/tmp/hexe/{s}/record-{s}.state", .{ safe, @tagName(scope) });
}

fn sanitizeInstance(buf: []u8, input: []const u8) []const u8 {
    var n: usize = 0;
    for (input) |ch| {
        if (n >= buf.len) break;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-') {
            buf[n] = ch;
            n += 1;
        }
    }
    if (n == 0) {
        const d = "default";
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
    return buf[0..n];
}

fn saveState(allocator: std.mem.Allocator, path: []const u8, st: RecordState) !void {
    const capture_input_u8: u8 = if (st.capture_input) 1 else 0;
    const payload = try std.fmt.allocPrint(allocator, "pid={d}\nscope={s}\nuuid={s}\nname={s}\nsocket={s}\nout={s}\ncapture_input={d}\nstarted_ms={d}\n", .{
        st.pid,
        @tagName(st.scope),
        st.uuid,
        st.name,
        st.socket,
        st.out,
        capture_input_u8,
        st.started_ms,
    });
    defer allocator.free(payload);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = payload });
}

fn loadState(allocator: std.mem.Allocator, path: []const u8) !?RecordState {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024) catch return null;
    errdefer allocator.free(data);

    var st = RecordState{};
    var lines = std.mem.tokenizeAny(u8, data, "\n");
    while (lines.next()) |line| {
        var kv = std.mem.splitScalar(u8, line, '=');
        const k = kv.first();
        const v = kv.next() orelse "";
        if (std.mem.eql(u8, k, "pid")) st.pid = std.fmt.parseInt(i32, v, 10) catch 0;
        if (std.mem.eql(u8, k, "scope")) st.scope = .pod;
        if (std.mem.eql(u8, k, "uuid")) st.uuid = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "name")) st.name = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "socket")) st.socket = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "out")) st.out = try allocator.dupe(u8, v);
        if (std.mem.eql(u8, k, "capture_input")) st.capture_input = (std.fmt.parseInt(u8, v, 10) catch 0) != 0;
        if (std.mem.eql(u8, k, "started_ms")) st.started_ms = std.fmt.parseInt(i64, v, 10) catch 0;
    }
    allocator.free(data);
    return st;
}

fn freeState(allocator: std.mem.Allocator, st: RecordState) void {
    if (st.uuid.len > 0) allocator.free(st.uuid);
    if (st.name.len > 0) allocator.free(st.name);
    if (st.socket.len > 0) allocator.free(st.socket);
    if (st.out.len > 0) allocator.free(st.out);
}
