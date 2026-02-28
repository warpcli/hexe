const std = @import("std");

pub const AsciicastOptions = struct {
    width: u16,
    height: u16,
    title: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

pub const AsciicastWriter = struct {
    file: std.fs.File,
    start_ms: i64,

    pub fn init(path: []const u8, opts: AsciicastOptions) !AsciicastWriter {
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) {
                try std.fs.cwd().makePath(dir);
            }
        }

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o644 });
        errdefer file.close();

        var writer = AsciicastWriter{
            .file = file,
            .start_ms = std.time.milliTimestamp(),
        };
        try writer.writeHeader(opts);
        return writer;
    }

    pub fn deinit(self: *AsciicastWriter) void {
        self.file.close();
        self.* = undefined;
    }

    pub fn writeOutput(self: *AsciicastWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.writeEvent('o', bytes);
    }

    pub fn writeInput(self: *AsciicastWriter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.writeEvent('i', bytes);
    }

    pub fn flush(self: *AsciicastWriter) !void {
        try self.file.sync();
    }

    fn writeHeader(self: *AsciicastWriter, opts: AsciicastOptions) !void {
        try self.file.writeAll("{\"version\":2,\"width\":");
        try writeInt(&self.file, opts.width);
        try self.file.writeAll(",\"height\":");
        try writeInt(&self.file, opts.height);
        try self.file.writeAll(",\"timestamp\":");
        try writeInt(&self.file, std.time.timestamp());

        if (opts.title) |title| {
            try self.file.writeAll(",\"title\":");
            try writeJsonStringEscaped(&self.file, title);
        }

        if (opts.command) |command| {
            try self.file.writeAll(",\"command\":");
            try writeJsonStringEscaped(&self.file, command);
        }

        try self.file.writeAll("}\n");
    }

    fn writeEvent(self: *AsciicastWriter, kind: u8, bytes: []const u8) !void {
        const elapsed_ms = std.time.milliTimestamp() - self.start_ms;
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        try self.file.writeAll("[");
        try writeFloat3(&self.file, elapsed_s);
        try self.file.writeAll(",\"");
        _ = try self.file.write(&[_]u8{kind});
        try self.file.writeAll("\",");
        try writeJsonStringEscaped(&self.file, bytes);
        try self.file.writeAll("]\n");
    }
};

fn writeJsonStringEscaped(file: *std.fs.File, input: []const u8) !void {
    _ = try file.write(&[_]u8{'"'});
    for (input) |ch| {
        switch (ch) {
            '"' => try file.writeAll("\\\""),
            '\\' => try file.writeAll("\\\\"),
            '\n' => try file.writeAll("\\n"),
            '\r' => try file.writeAll("\\r"),
            '\t' => try file.writeAll("\\t"),
            0x08 => try file.writeAll("\\b"),
            0x0c => try file.writeAll("\\f"),
            else => {
                if (ch < 0x20) {
                    var esc_buf: [6]u8 = undefined;
                    const esc = try std.fmt.bufPrint(&esc_buf, "\\u00{x:0>2}", .{ch});
                    try file.writeAll(esc);
                } else {
                    _ = try file.write(&[_]u8{ch});
                }
            },
        }
    }
    _ = try file.write(&[_]u8{'"'});
}

fn writeInt(file: *std.fs.File, value: anytype) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try file.writeAll(s);
}

fn writeFloat3(file: *std.fs.File, value: f64) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.3}", .{value});
    try file.writeAll(s);
}
