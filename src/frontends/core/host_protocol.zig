const std = @import("std");

const events = @import("events.zig");

/// Minimal line-oriented host protocol used by early non-terminal serving
/// loops. It is intentionally frontend-neutral: web/syslink can put this over
/// stdio, a socket, websocket messages, or a remote transport without changing
/// the core event mapping.
pub const HostProtocolAction = union(enum) {
    host_event: events.HostEvent,
    render,
    exit,
};

pub const ParseError = error{
    InvalidCommand,
    InvalidResize,
};

pub fn parseLine(line: []const u8) ParseError!HostProtocolAction {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "tick")) {
        return .{ .host_event = .tick };
    }
    if (std.mem.eql(u8, trimmed, "render")) return .render;
    if (std.mem.eql(u8, trimmed, "close")) return .{ .host_event = .close_requested };
    if (std.mem.eql(u8, trimmed, "exit")) return .exit;
    if (std.mem.eql(u8, trimmed, "disconnect")) {
        return .{ .host_event = .{ .connection_lost = .transport_lost } };
    }
    if (std.mem.startsWith(u8, trimmed, "resize ")) {
        var it = std.mem.tokenizeScalar(u8, trimmed["resize ".len..], ' ');
        const cols_text = it.next() orelse return error.InvalidResize;
        const rows_text = it.next() orelse return error.InvalidResize;
        if (it.next() != null) return error.InvalidResize;
        const cols = std.fmt.parseInt(u16, cols_text, 10) catch return error.InvalidResize;
        const rows = std.fmt.parseInt(u16, rows_text, 10) catch return error.InvalidResize;
        return .{ .host_event = .{ .resize = .{ .cols = cols, .rows = rows } } };
    }
    if (std.mem.startsWith(u8, trimmed, "input ")) {
        return .{ .host_event = .{ .input_bytes = trimmed["input ".len..] } };
    }
    if (std.mem.startsWith(u8, trimmed, "paste ")) {
        return .{ .host_event = .{ .paste = trimmed["paste ".len..] } };
    }
    return error.InvalidCommand;
}

test "host protocol parses lifecycle commands" {
    try std.testing.expect(std.meta.activeTag((try parseLine("render"))) == .render);
    try std.testing.expect(std.meta.activeTag((try parseLine("exit"))) == .exit);
    const close = (try parseLine("close")).host_event;
    try std.testing.expect(std.meta.activeTag(close) == .close_requested);
    const lost = (try parseLine("disconnect")).host_event;
    try std.testing.expectEqual(events.DisconnectReason.transport_lost, lost.connection_lost);
}

test "host protocol parses resize and input commands" {
    const resize = (try parseLine("resize 120 40")).host_event;
    try std.testing.expectEqual(@as(u16, 120), resize.resize.cols);
    try std.testing.expectEqual(@as(u16, 40), resize.resize.rows);

    const input = (try parseLine("input abc")).host_event;
    try std.testing.expectEqualStrings("abc", input.input_bytes);

    try std.testing.expectError(error.InvalidResize, parseLine("resize 1"));
}
