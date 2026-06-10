const std = @import("std");
const core = @import("core");

/// Frontend-neutral resize event. Terminal hosts map TTY size changes here;
/// future web/syslink hosts can map browser or remote-terminal resizes here.
pub const Resize = struct {
    cols: u16,
    rows: u16,
};

/// Frontend-neutral key event placeholder. Keep this intentionally small until
/// terminal key parsing is split from action dispatch.
pub const KeyEvent = struct {
    key: u32,
    mods: u8 = 0,
};

/// Frontend-neutral mouse event placeholder. Coordinates are cells for now
/// because the terminal host is the only implemented host; a later host
/// capability pass can distinguish cells from pixels.
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: u8 = 0,
    mods: u8 = 0,
};

/// Frontend-neutral connection loss reason.
///
/// Keep this separate from the SES wire disconnect mode: hosts use this for UI
/// and reconnection policy, while the wire protocol can serialize a compact
/// reason when the frontend is still healthy enough to notify SES.
pub const DisconnectReason = enum {
    unknown,
    host_closed,
    transport_lost,
    frontend_io_error,
};

/// Events a concrete host can feed into the frontend core.
pub const HostEvent = union(enum) {
    input_bytes: []const u8,
    key: KeyEvent,
    mouse: MouseEvent,
    paste: []const u8,
    resize: Resize,
    tick,
    close_requested,
    connection_lost: DisconnectReason,
};

/// Commands/events the frontend core can emit back to a concrete host.
pub const HostCommand = union(enum) {
    render,
    notify: []const u8,
    set_cursor,
    set_clipboard: []const u8,
    exit,
};

pub const StopKind = enum {
    frontend_disconnect,
    session_stolen,
    explicit_detach,
};

/// Frontend-neutral stop request distilled from the runtime's attach state.
pub const StopRequest = struct {
    kind: StopKind,
    detach: bool,
    user_message: ?[]const u8 = null,
};

/// Convert the runtime stop reason into a frontend-neutral request. This is the
/// first low-risk behavior moved behind the host-adapter boundary: terminal can
/// still render the message itself, while future hosts can present the same
/// semantic event in their own UI.
pub fn stopRequestFromRuntime(reason: core.FrontendAttachState.StopReason) ?StopRequest {
    return switch (reason) {
        .none => null,
        .frontend_disconnect => .{
            .kind = .frontend_disconnect,
            .detach = true,
        },
        .session_stolen => .{
            .kind = .session_stolen,
            .detach = true,
            .user_message = "Session attached elsewhere; this client is closing",
        },
        .explicit_detach => .{
            .kind = .explicit_detach,
            .detach = true,
        },
    };
}

test "stopRequestFromRuntime maps session stolen to host-visible notification" {
    const req = stopRequestFromRuntime(.session_stolen).?;

    try std.testing.expectEqual(StopKind.session_stolen, req.kind);
    try std.testing.expect(req.detach);
    try std.testing.expectEqualStrings(
        "Session attached elsewhere; this client is closing",
        req.user_message.?,
    );
}

test "stopRequestFromRuntime ignores none" {
    try std.testing.expect(stopRequestFromRuntime(.none) == null);
}

test "host event resize keeps terminal-independent dimensions" {
    const ev = HostEvent{ .resize = .{ .cols = 120, .rows = 40 } };
    try std.testing.expectEqual(@as(u16, 120), ev.resize.cols);
    try std.testing.expectEqual(@as(u16, 40), ev.resize.rows);
}

test "host event connection loss carries a structured reason" {
    const ev = HostEvent{ .connection_lost = .transport_lost };
    try std.testing.expectEqual(DisconnectReason.transport_lost, ev.connection_lost);
}
