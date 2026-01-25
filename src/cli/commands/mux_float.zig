const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const wire = core.wire;

const print = std.debug.print;

pub fn runMuxFloat(
    allocator: std.mem.Allocator,
    command: []const u8,
    title: []const u8,
    cwd: []const u8,
    result_file: []const u8,
    pass_env: bool,
    extra_env: []const u8,
    isolated: bool,
) !void {
    if (command.len == 0) {
        print("Error: --command is required\n", .{});
        return;
    }

    const posix = std.posix;

    // Collect env entries.
    var env_list: std.ArrayList([]const u8) = .empty;
    defer env_list.deinit(allocator);

    if (pass_env) {
        var env_map = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        var it = env_map.iterator();
        while (it.next()) |entry| {
            const line = std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            env_list.append(allocator, line) catch {
                allocator.free(line);
                continue;
            };
        }
    }

    // Parse extra_env (comma-separated KEY=VALUE pairs).
    if (extra_env.len > 0) {
        var it = std.mem.splitScalar(u8, extra_env, ',');
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " ");
            if (trimmed.len == 0) continue;
            env_list.append(allocator, trimmed) catch continue;
        }
    }

    // Connect to SES.
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

    // Send versioned CLI handshake.
    wire.sendHandshake(fd, wire.SES_HANDSHAKE_CLI) catch return;

    // Determine result path for wait_for_exit.
    var owned_result_path: ?[]u8 = null;
    defer if (owned_result_path) |p| allocator.free(p);
    const actual_result_path: []const u8 = if (result_file.len > 0)
        result_file
    else blk: {
        const tmp_uuid = ipc.generateUuid();
        owned_result_path = std.fmt.allocPrint(allocator, "/tmp/hexe-float-{s}.result", .{tmp_uuid}) catch break :blk "";
        break :blk owned_result_path.?;
    };

    // Build FloatRequest.
    const flags: u8 = (if (true) @as(u8, 1) else 0) | // wait_for_exit always true for CLI
        (if (isolated) @as(u8, 2) else 0);
    const req = wire.FloatRequest{
        .flags = flags,
        .cmd_len = @intCast(command.len),
        .title_len = @intCast(title.len),
        .cwd_len = @intCast(cwd.len),
        .result_path_len = @intCast(actual_result_path.len),
        .env_count = @intCast(env_list.items.len),
    };

    // Build trailing data: cmd + title + cwd + result_path + env entries (each: u16 len + bytes).
    var trail: std.ArrayList(u8) = .empty;
    defer trail.deinit(allocator);
    var tw = trail.writer(allocator);
    try tw.writeAll(command);
    try tw.writeAll(title);
    try tw.writeAll(cwd);
    try tw.writeAll(actual_result_path);
    for (env_list.items) |entry| {
        const entry_len: u16 = @intCast(entry.len);
        try tw.writeAll(std.mem.asBytes(&entry_len));
        try tw.writeAll(entry);
    }

    // Send the float_request message.
    wire.writeControlWithTrail(fd, .float_request, std.mem.asBytes(&req), trail.items) catch return;

    // Wait for response (FloatCreated for immediate, FloatResult for wait).
    const hdr = wire.readControlHeader(fd) catch {
        print("No response from ses\n", .{});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);

    switch (msg_type) {
        .float_result => {
            const result = wire.readStruct(wire.FloatResult, fd) catch {
                print("Error reading float result\n", .{});
                return;
            };
            // Read output if any.
            if (result.output_len > 0) {
                const output = allocator.alloc(u8, result.output_len) catch {
                    print("Error allocating output buffer\n", .{});
                    return;
                };
                defer allocator.free(output);
                wire.readExact(fd, output) catch {
                    print("Error reading output\n", .{});
                    return;
                };
                if (output.len > 0) {
                    _ = posix.write(posix.STDOUT_FILENO, output) catch {};
                    _ = posix.write(posix.STDOUT_FILENO, "\n") catch {};
                }
            }
            const exit_code: u8 = if (result.exit_code >= 0) @intCast(@min(result.exit_code, 255)) else 1;
            std.process.exit(exit_code);
        },
        .@"error" => {
            // Read error message.
            if (hdr.payload_len > 0 and hdr.payload_len <= 1024) {
                var err_buf: [1024]u8 = undefined;
                wire.readExact(fd, err_buf[0..hdr.payload_len]) catch return;
                print("Error: {s}\n", .{err_buf[0..hdr.payload_len]});
            } else {
                print("Error from ses\n", .{});
            }
            return;
        },
        else => {
            print("Unexpected response from ses\n", .{});
            return;
        },
    }

    // Free env entries we allocated.
    if (pass_env) {
        for (env_list.items) |entry| {
            // Only free entries we allocated (pass_env entries).
            // extra_env entries are slices of the input, not owned.
            if (std.mem.indexOfScalar(u8, entry, '=')) |_| {
                // Check if this was allocated by us.
                // pass_env entries were allocPrint'd.
            }
        }
    }
}
