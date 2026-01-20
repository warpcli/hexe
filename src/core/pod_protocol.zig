const std = @import("std");
const posix = std.posix;
const ipc = @import("ipc.zig");

pub const MAX_FRAME_LEN: usize = 4 * 1024 * 1024;

pub const FrameType = enum(u8) {
    output = 1,
    input = 2,
    resize = 3,
    backlog_end = 4,
};

pub fn writeFrame(conn: *ipc.Connection, frame_type: FrameType, payload: []const u8) !void {
    if (payload.len > std.math.maxInt(u32)) return error.FrameTooLarge;

    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(frame_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .big);

    try conn.send(&header);
    if (payload.len > 0) {
        try conn.send(payload);
    }
}

pub const Frame = struct {
    frame_type: FrameType,
    payload: []const u8,
};

/// Incremental framed stream reader.
///
/// Call `feed()` with newly received bytes; it invokes the callback once
/// per complete frame.
pub const Reader = struct {
    header: [5]u8 = .{ 0, 0, 0, 0, 0 },
    header_len: usize = 0,

    frame_type: FrameType = .output,
    frame_len: usize = 0,
    payload_buf: []u8 = &[_]u8{},
    payload_len: usize = 0,
    skipping: bool = false,
    skip_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_len: usize) !Reader {
        return .{ .payload_buf = try allocator.alloc(u8, max_len) };
    }

    pub fn deinit(self: *Reader, allocator: std.mem.Allocator) void {
        allocator.free(self.payload_buf);
        self.* = undefined;
    }

    pub fn reset(self: *Reader) void {
        self.header_len = 0;
        self.frame_len = 0;
        self.payload_len = 0;
        self.skipping = false;
        self.skip_len = 0;
    }

    pub fn feed(self: *Reader, data: []const u8, ctx: *anyopaque, on_frame: *const fn (*anyopaque, Frame) void) void {
        var i: usize = 0;
        while (i < data.len) {
            if (self.skipping) {
                const take = @min(self.skip_len, data.len - i);
                self.skip_len -= take;
                i += take;
                if (self.skip_len == 0) {
                    self.skipping = false;
                    self.header_len = 0;
                }
                continue;
            }
            if (self.header_len < self.header.len) {
                const take = @min(self.header.len - self.header_len, data.len - i);
                @memcpy(self.header[self.header_len .. self.header_len + take], data[i .. i + take]);
                self.header_len += take;
                i += take;

                if (self.header_len == self.header.len) {
                    self.frame_type = @enumFromInt(self.header[0]);
                    self.frame_len = std.mem.readInt(u32, self.header[1..5], .big);
                    self.payload_len = 0;

                    if (self.frame_len > self.payload_buf.len) {
                        self.skipping = true;
                        self.skip_len = self.frame_len;
                        continue;
                    }

                    if (self.frame_len == 0) {
                        on_frame(ctx, .{ .frame_type = self.frame_type, .payload = &[_]u8{} });
                        self.header_len = 0;
                    }
                }
                continue;
            }

            const take = @min(self.frame_len - self.payload_len, data.len - i);
            if (take > 0) {
                @memcpy(self.payload_buf[self.payload_len .. self.payload_len + take], data[i .. i + take]);
                self.payload_len += take;
                i += take;
            }

            if (self.payload_len == self.frame_len) {
                on_frame(ctx, .{ .frame_type = self.frame_type, .payload = self.payload_buf[0..self.payload_len] });
                self.header_len = 0;
            }
        }
    }
};

pub fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}
