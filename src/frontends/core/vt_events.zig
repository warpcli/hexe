const std = @import("std");
const core = @import("core");

const posix = std.posix;
const pod_protocol = core.pod_protocol;
const wire = core.wire;

/// Frontend-neutral meaning of a multiplexed VT frame.
///
/// Keep this separate from terminal rendering so non-terminal hosts can process
/// the same SES/POD stream without importing terminal loop code.
pub const VtFrameKind = enum {
    output,
    backlog_end,
    ignored,
};

pub const VtFrameEvent = struct {
    pane_id: u16,
    raw_frame_type: u8,
    kind: VtFrameKind,
    payload_len: u32,
};

pub const VtFrameReadResult = union(enum) {
    frame: VtFrameEvent,
    drained_oversized: VtFrameEvent,
    would_block,
};

pub fn vtFrameKindFromRaw(frame_type: u8) VtFrameKind {
    if (frame_type == @intFromEnum(pod_protocol.FrameType.output)) return .output;
    if (frame_type == @intFromEnum(pod_protocol.FrameType.backlog_end)) return .backlog_end;
    return .ignored;
}

pub fn vtFrameEventFromHeader(header: wire.MuxVtHeader) VtFrameEvent {
    return .{
        .pane_id = header.pane_id,
        .raw_frame_type = header.frame_type,
        .kind = vtFrameKindFromRaw(header.frame_type),
        .payload_len = header.len,
    };
}

/// Read one multiplexed VT frame into `buffer`.
///
/// This keeps frame IO mechanics out of concrete hosts. Hosts still decide how
/// to apply output/backlog events to their view models.
pub fn readMuxVtFrame(fd: posix.fd_t, buffer: []u8) !VtFrameReadResult {
    const header = wire.tryReadMuxVtHeader(fd) catch |err| switch (err) {
        error.WouldBlock => return .would_block,
        else => return err,
    };
    const event = vtFrameEventFromHeader(header);

    if (header.len > buffer.len) {
        var remaining: usize = header.len;
        while (remaining > 0) {
            const chunk = @min(remaining, buffer.len);
            try wire.readExact(fd, buffer[0..chunk]);
            remaining -= chunk;
        }
        return .{ .drained_oversized = event };
    }

    if (header.len > 0) {
        try wire.readExact(fd, buffer[0..header.len]);
    }

    return .{ .frame = event };
}

/// Drain available multiplexed VT frames and dispatch their frontend-neutral
/// meaning to callbacks.
///
/// For normal frames, `payload` aliases `buffer` and is valid only until the
/// next drain iteration. Oversized frames are drained and reported without a
/// payload because their bytes do not fit the caller-provided buffer.
pub fn drainMuxVtFrames(
    fd: posix.fd_t,
    buffer: []u8,
    max_frames: usize,
    context: anytype,
    comptime on_frame: fn (@TypeOf(context), VtFrameEvent, []const u8) bool,
    comptime on_oversized: fn (@TypeOf(context), VtFrameEvent) bool,
) !void {
    var frames: usize = 0;
    while (frames < max_frames) : (frames += 1) {
        switch (try readMuxVtFrame(fd, buffer)) {
            .would_block => break,
            .drained_oversized => |event| {
                if (!on_oversized(context, event)) break;
            },
            .frame => |event| {
                const payload_len: usize = @intCast(event.payload_len);
                if (!on_frame(context, event, buffer[0..payload_len])) break;
            },
        }
    }
}

fn testVtDrainNoopFrame(_: void, _: VtFrameEvent, _: []const u8) bool {
    return true;
}

fn testVtDrainNoopOversized(_: void, _: VtFrameEvent) bool {
    return true;
}

test "vtFrameKindFromRaw classifies frontend-relevant frames" {
    try std.testing.expectEqual(
        VtFrameKind.output,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.output)),
    );
    try std.testing.expectEqual(
        VtFrameKind.backlog_end,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.backlog_end)),
    );
}

test "vtFrameKindFromRaw ignores pod-only frames" {
    try std.testing.expectEqual(
        VtFrameKind.ignored,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.input)),
    );
    try std.testing.expectEqual(
        VtFrameKind.ignored,
        vtFrameKindFromRaw(@intFromEnum(pod_protocol.FrameType.resize)),
    );
}

test "vtFrameEventFromHeader preserves pane id and payload length" {
    const event = vtFrameEventFromHeader(.{
        .pane_id = 42,
        .frame_type = @intFromEnum(pod_protocol.FrameType.output),
        .len = 1234,
    });

    try std.testing.expectEqual(@as(u16, 42), event.pane_id);
    try std.testing.expectEqual(@as(u8, @intFromEnum(pod_protocol.FrameType.output)), event.raw_frame_type);
    try std.testing.expectEqual(VtFrameKind.output, event.kind);
    try std.testing.expectEqual(@as(u32, 1234), event.payload_len);
}

test "drainMuxVtFrames accepts an empty drain without touching fd" {
    const invalid_fd: posix.fd_t = -1;
    var buffer: [1]u8 = undefined;
    try drainMuxVtFrames(invalid_fd, &buffer, 0, {}, testVtDrainNoopFrame, testVtDrainNoopOversized);
}
