const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const com = @import("com.zig");

const print = std.debug.print;

/// Run `hexe ses freeze` — snapshot current session as .hexe.lua to stdout.
pub fn runSesFreeze(allocator: std.mem.Allocator) !void {
    const wire = core.wire;
    const posix = std.posix;

    // Get current pane UUID from environment
    const uuid_str = posix.getenv("HEXE_PANE_UUID") orelse {
        print("Error: not inside a hexe mux session (HEXE_PANE_UUID not set)\n", .{});
        return;
    };
    if (uuid_str.len < 32) {
        print("Error: invalid HEXE_PANE_UUID\n", .{});
        return;
    }
    var uuid_arr: [32]u8 = undefined;
    @memcpy(&uuid_arr, uuid_str[0..32]);

    // Connect to SES and request mux state
    const fd = com.connectSesCliChannel(allocator) orelse return;
    defer posix.close(fd);

    var pu: wire.PaneUuid = .{ .uuid = undefined };
    pu.uuid = uuid_arr;
    wire.writeControl(fd, .get_layout, std.mem.asBytes(&pu)) catch {
        print("Error: failed to send request\n", .{});
        return;
    };

    // Read response
    const hdr = wire.readControlHeader(fd) catch {
        print("Error: failed to read response\n", .{});
        return;
    };
    const msg_type: wire.MsgType = @enumFromInt(hdr.msg_type);
    if (msg_type == .@"error") {
        print("Error: server returned error\n", .{});
        return;
    }
    if (msg_type != .get_layout or hdr.payload_len == 0) {
        print("Error: unexpected response\n", .{});
        return;
    }

    // Read raw mux state JSON
    const mux_state = allocator.alloc(u8, hdr.payload_len) catch {
        print("Error: allocation failed\n", .{});
        return;
    };
    defer allocator.free(mux_state);
    wire.readExact(fd, mux_state) catch {
        print("Error: failed to read mux state\n", .{});
        return;
    };

    // Parse the mux state JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, mux_state, .{}) catch {
        print("Error: failed to parse mux state\n", .{});
        return;
    };
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            print("Error: invalid mux state format\n", .{});
            return;
        },
    };

    // Get session name
    const session_name = if (root_obj.get("session_name")) |n|
        switch (n) {
            .string => |s| s,
            else => "session",
        }
    else
        "session";

    // Get current working directory as root
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch "/tmp";

    // Output .hexe.lua to stdout
    const stdout = std.fs.File.stdout();

    stdout.writeAll("return {\n") catch return;
    w(stdout, "  name = \"{s}\",\n", .{session_name});
    writeLuaString(stdout, "  root = \"", cwd, "\",\n") catch return;

    // Tabs
    const tabs_val = root_obj.get("tabs") orelse {
        stdout.writeAll("}\n") catch {};
        return;
    };
    const tabs_arr = switch (tabs_val) {
        .array => |a| a,
        else => {
            stdout.writeAll("}\n") catch {};
            return;
        },
    };

    // Build a CWD map for all panes across all tabs
    stdout.writeAll("  tabs = {\n") catch return;

    for (tabs_arr.items, 0..) |tab_val, ti| {
        const tab = switch (tab_val) {
            .object => |o| o,
            else => continue,
        };

        const tab_name = if (tab.get("name")) |n|
            switch (n) {
                .string => |s| s,
                else => "tab",
            }
        else
            "tab";

        // Build CWD map from splits array for this tab
        var cwd_map = std.AutoHashMap(i64, []const u8).init(allocator);
        defer cwd_map.deinit();
        if (tab.get("splits")) |splits_val| {
            switch (splits_val) {
                .array => |splits_arr| {
                    for (splits_arr.items) |split_item| {
                        switch (split_item) {
                            .object => |split_obj| {
                                const id_val = split_obj.get("id") orelse continue;
                                const id = switch (id_val) {
                                    .integer => |i| i,
                                    else => continue,
                                };
                                if (split_obj.get("pwd_dir")) |pwd_val| {
                                    switch (pwd_val) {
                                        .string => |s| cwd_map.put(id, s) catch {},
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        stdout.writeAll("    {\n") catch return;
        w(stdout, "      name = \"{s}\",\n", .{tab_name});

        // Check if there's a tree (split structure)
        if (tab.get("tree")) |tree_val| {
            const tree_obj = switch (tree_val) {
                .object => |o| o,
                else => null,
            };
            if (tree_obj) |tree| {
                const type_str = if (tree.get("type")) |t|
                    switch (t) {
                        .string => |s| s,
                        else => null,
                    }
                else
                    null;

                if (type_str) |ts| {
                    if (std.mem.eql(u8, ts, "split")) {
                        stdout.writeAll("      split = ") catch return;
                        writeLuaSplitTree(stdout, tree, &cwd_map, cwd, 3) catch return;
                        stdout.writeAll(",\n") catch return;
                    } else if (std.mem.eql(u8, ts, "pane")) {
                        // Single pane — check for cmd/cwd
                        const pane_id = if (tree.get("id")) |id_val|
                            switch (id_val) {
                                .integer => |i| i,
                                else => null,
                            }
                        else
                            null;
                        if (pane_id) |pid| {
                            if (cwd_map.get(pid)) |pane_cwd| {
                                if (!std.mem.eql(u8, pane_cwd, cwd)) {
                                    w(stdout, "      split = {{ cwd = \"{s}\" }},\n", .{pane_cwd});
                                }
                            }
                        }
                    }
                }
            }
        }

        stdout.writeAll("    }") catch return;
        if (ti + 1 < tabs_arr.items.len) stdout.writeAll(",") catch {};
        stdout.writeAll("\n") catch return;
    }

    stdout.writeAll("  },\n") catch return;

    // Floats
    const floats_val = root_obj.get("floats");
    if (floats_val) |fv| {
        switch (fv) {
            .array => |floats_arr| {
                if (floats_arr.items.len > 0) {
                    stdout.writeAll("  floats = {\n") catch return;
                    for (floats_arr.items, 0..) |float_val, fi| {
                        const float = switch (float_val) {
                            .object => |o| o,
                            else => continue,
                        };

                        stdout.writeAll("    {") catch return;

                        if (float.get("float_key")) |key_val| {
                            switch (key_val) {
                                .integer => |k| {
                                    if (k > 0 and k < 128) {
                                        const key_char: u8 = @intCast(k);
                                        w(stdout, " key = \"{c}\",", .{key_char});
                                    }
                                },
                                else => {},
                            }
                        }

                        if (float.get("float_width_pct")) |wv| {
                            switch (wv) {
                                .integer => |v| w(stdout, " width = {d},", .{v}),
                                else => {},
                            }
                        }
                        if (float.get("float_height_pct")) |h| {
                            switch (h) {
                                .integer => |v| w(stdout, " height = {d},", .{v}),
                                else => {},
                            }
                        }

                        stdout.writeAll(" }") catch return;
                        if (fi + 1 < floats_arr.items.len) stdout.writeAll(",") catch {};
                        stdout.writeAll("\n") catch return;
                    }
                    stdout.writeAll("  },\n") catch return;
                }
            },
            else => {},
        }
    }

    stdout.writeAll("}\n") catch return;
}

/// Helper: formatted write to a File using a stack buffer.
fn w(file: std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    file.writeAll(str) catch {};
}

fn writeLuaSplitTree(file: std.fs.File, obj: std.json.ObjectMap, cwd_map: *std.AutoHashMap(i64, []const u8), root_cwd: []const u8, indent: usize) std.fs.File.WriteError!void {
    const type_str = if (obj.get("type")) |t|
        switch (t) {
            .string => |s| s,
            else => return,
        }
    else
        return;

    if (std.mem.eql(u8, type_str, "pane")) {
        try file.writeAll("{");

        const pane_id = if (obj.get("id")) |id_val|
            switch (id_val) {
                .integer => |i| i,
                else => null,
            }
        else
            null;

        if (pane_id) |pid| {
            if (cwd_map.get(pid)) |pane_cwd| {
                if (!std.mem.eql(u8, pane_cwd, root_cwd)) {
                    var buf: [4096]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, " cwd = \"{s}\"", .{pane_cwd}) catch return;
                    try file.writeAll(str);
                }
            }
        }
        try file.writeAll(" }");
    } else if (std.mem.eql(u8, type_str, "split")) {
        try file.writeAll("{\n");

        // Direction
        const dir_str = if (obj.get("dir")) |d|
            switch (d) {
                .string => |s| s,
                else => "horizontal",
            }
        else
            "horizontal";
        try writeIndent(file, indent + 1);
        var dir_buf: [256]u8 = undefined;
        const dir_line = std.fmt.bufPrint(&dir_buf, "dir = \"{s}\",\n", .{dir_str}) catch return;
        try file.writeAll(dir_line);

        // Ratio — calculate sizes from it
        const ratio: f64 = if (obj.get("ratio")) |r|
            switch (r) {
                .float => r.float,
                .integer => @floatFromInt(r.integer),
                else => 0.5,
            }
        else
            0.5;

        const size_first: u8 = @intFromFloat(@round(ratio * 100.0));
        const size_second: u8 = 100 - size_first;

        // Emit first child with size
        if (obj.get("first")) |f_val| {
            switch (f_val) {
                .object => |f| {
                    try writeIndent(file, indent + 1);
                    try writeLuaSplitChildWithSize(file, f, cwd_map, root_cwd, size_first, indent + 1);
                    try file.writeAll(",\n");
                },
                else => {},
            }
        }

        // Emit second child with size
        if (obj.get("second")) |s_val| {
            switch (s_val) {
                .object => |s| {
                    try writeIndent(file, indent + 1);
                    try writeLuaSplitChildWithSize(file, s, cwd_map, root_cwd, size_second, indent + 1);
                    try file.writeAll(",\n");
                },
                else => {},
            }
        }

        try writeIndent(file, indent);
        try file.writeAll("}");
    }
}

fn writeLuaSplitChildWithSize(file: std.fs.File, obj: std.json.ObjectMap, cwd_map: *std.AutoHashMap(i64, []const u8), root_cwd: []const u8, size: u8, indent: usize) std.fs.File.WriteError!void {
    const type_str = if (obj.get("type")) |t|
        switch (t) {
            .string => |s| s,
            else => return,
        }
    else
        return;

    if (std.mem.eql(u8, type_str, "pane")) {
        var buf: [4096]u8 = undefined;
        const hdr = std.fmt.bufPrint(&buf, "{{ size = {d}", .{size}) catch return;
        try file.writeAll(hdr);

        const pane_id = if (obj.get("id")) |id_val|
            switch (id_val) {
                .integer => |i| i,
                else => null,
            }
        else
            null;

        if (pane_id) |pid| {
            if (cwd_map.get(pid)) |pane_cwd| {
                if (!std.mem.eql(u8, pane_cwd, root_cwd)) {
                    const cwd_str = std.fmt.bufPrint(&buf, ", cwd = \"{s}\"", .{pane_cwd}) catch return;
                    try file.writeAll(cwd_str);
                }
            }
        }
        try file.writeAll(" }");
    } else if (std.mem.eql(u8, type_str, "split")) {
        // Nested split — emit as a full split table with size
        var buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&buf, "{{ size = {d}, ", .{size}) catch return;
        try file.writeAll(hdr);
        try writeLuaSplitTree(file, obj, cwd_map, root_cwd, indent);
        try file.writeAll(" }");
    }
}

fn writeIndent(file: std.fs.File, level: usize) std.fs.File.WriteError!void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try file.writeAll("  ");
    }
}

fn writeLuaString(file: std.fs.File, prefix: []const u8, value: []const u8, suffix: []const u8) !void {
    try file.writeAll(prefix);
    for (value) |ch| {
        switch (ch) {
            '\\' => try file.writeAll("\\\\"),
            '"' => try file.writeAll("\\\""),
            '\n' => try file.writeAll("\\n"),
            '\r' => try file.writeAll("\\r"),
            '\t' => try file.writeAll("\\t"),
            else => try file.writeAll(&[_]u8{ch}),
        }
    }
    try file.writeAll(suffix);
}
