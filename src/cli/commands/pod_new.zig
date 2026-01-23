const std = @import("std");
const core = @import("core");
const ipc = core.ipc;

const print = std.debug.print;

pub fn runPodNew(
    allocator: std.mem.Allocator,
    name: []const u8,
    shell: []const u8,
    cwd: []const u8,
    labels: []const u8,
    alias: bool,
    debug: bool,
    log_file: []const u8,
) !void {
    const uuid = ipc.generateUuid();
    const uuid_str = uuid[0..];
    const pod_socket_path = try ipc.getPodSocketPath(allocator, uuid_str);
    defer allocator.free(pod_socket_path);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.append(allocator, exe_path);
    try args.append(allocator, "pod");
    try args.append(allocator, "daemon");

    // Preserve instance/test-only behavior by passing through flags (env still drives runtime dir).
    if (std.posix.getenv("HEXE_INSTANCE")) |inst| {
        if (inst.len > 0) {
            try args.append(allocator, "--instance");
            try args.append(allocator, inst);
        }
    }
    if (std.posix.getenv("HEXE_TEST_ONLY")) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
            try args.append(allocator, "--test-only");
        }
    }

    try args.append(allocator, "--uuid");
    try args.append(allocator, uuid_str);
    if (name.len > 0) {
        try args.append(allocator, "--name");
        try args.append(allocator, name);
    }
    try args.append(allocator, "--socket");
    try args.append(allocator, pod_socket_path);
    if (shell.len > 0) {
        try args.append(allocator, "--shell");
        try args.append(allocator, shell);
    }
    if (cwd.len > 0) {
        try args.append(allocator, "--cwd");
        try args.append(allocator, cwd);
    }
    if (labels.len > 0) {
        try args.append(allocator, "--labels");
        try args.append(allocator, labels);
    }
    if (alias) {
        try args.append(allocator, "--write-alias");
    }
    if (debug) {
        try args.append(allocator, "--debug");
    }
    if (log_file.len > 0) {
        try args.append(allocator, "--logfile");
        try args.append(allocator, log_file);
    }
    try args.append(allocator, "--foreground");

    // Spawn in foreground so we can read the existing ready handshake.
    var child = std.process.Child.init(args.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Pipe;

    try child.spawn();

    const pod_pid: i64 = @intCast(child.id);
    var stdout_file = child.stdout orelse return error.PodNoStdout;
    defer stdout_file.close();

    // Read JSON handshake line with timeout.
    const spawn_timeout_ms: i64 = 2500;
    const deadline_ms = std.time.milliTimestamp() + spawn_timeout_ms;
    const stdout_fd = stdout_file.handle;
    var line_buf: [512]u8 = undefined;
    var pos: usize = 0;
    while (pos < line_buf.len) {
        const remaining_ms = deadline_ms - std.time.milliTimestamp();
        if (remaining_ms <= 0) return error.PodSpawnTimeout;

        var pfd = [_]std.posix.pollfd{.{ .fd = stdout_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const rc = std.posix.poll(&pfd, @intCast(remaining_ms)) catch |err| return err;
        if (rc == 0) return error.PodSpawnTimeout;
        if (pfd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return error.PodNoHandshake;
        if (pfd[0].revents & std.posix.POLL.IN == 0) continue;

        var one: [1]u8 = undefined;
        const n = try stdout_file.read(&one);
        if (n == 0) break;
        if (one[0] == '\n') break;
        line_buf[pos] = one[0];
        pos += 1;
    }
    if (pos == 0) return error.PodNoHandshake;

    const line = line_buf[0..pos];
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const pid_val = (root.get("pid") orelse return error.PodBadHandshake).integer;
    const child_pid: i64 = @intCast(pid_val);

    // Detach the pod process (keep it running).
    // The pod was started with --foreground so it didn't daemonize, but we
    // still want `hexe pod new` to exit immediately after readiness.
    // We just print a single JSON line for scripting.
    var out_buf: [1024]u8 = undefined;
    const out = try std.fmt.bufPrint(
        &out_buf,
        "{{\"type\":\"pod_new\",\"uuid\":\"{s}\",\"socket\":\"{s}\",\"pod_pid\":{d},\"child_pid\":{d}}}\n",
        .{ uuid_str, pod_socket_path, pod_pid, child_pid },
    );
    _ = try std.fs.File.stdout().writeAll(out);
}
