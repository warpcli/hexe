const std = @import("std");
const core = @import("core");
const frontend_core = @import("frontend_core");

/// Syslink/ssh-like remote-terminal adapter event shape.
///
/// Syslink is not a renderer by itself: it should normalize remote terminal
/// bytes, remote resizes, and reconnect/close events before FrontendCore sees
/// them. Transport authentication/channel setup belongs below this adapter.
pub const RemoteTerminalEvent = union(enum) {
    terminal_bytes: []const u8,
    terminal_resize: frontend_core.Resize,
    paste: []const u8,
    heartbeat,
    remote_closed,
    transport_lost,
};

pub const SyslinkHost = struct {
    allocator: std.mem.Allocator,
    current_view: ?frontend_core.SessionView = null,

    pub fn init(allocator: std.mem.Allocator) SyslinkHost {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SyslinkHost) void {
        if (self.current_view) |*view| view.deinit();
        self.current_view = null;
    }

    pub fn capabilities() frontend_core.HostCapabilities {
        return frontend_core.defaultCapabilities(.desktop);
    }

    pub fn mapRemoteEvent(event: RemoteTerminalEvent) frontend_core.HostEvent {
        return switch (event) {
            .terminal_bytes => |bytes| .{ .input_bytes = bytes },
            .terminal_resize => |resize| .{ .resize = resize },
            .paste => |bytes| .{ .paste = bytes },
            .heartbeat => .tick,
            .remote_closed => .close_requested,
            .transport_lost => .{ .connection_lost = .transport_lost },
        };
    }

    /// Apply a remote SES session snapshot to the syslink adapter's shared
    /// frontend view. Transport reconnect code can rebuild presentation from
    /// this model without pretending to be local terminal state.
    pub fn applySessionStateJson(self: *SyslinkHost, session_json: []const u8) !void {
        var next = try frontend_core.SessionView.fromJson(self.allocator, session_json);
        errdefer next.deinit();
        if (self.current_view) |*old| old.deinit();
        self.current_view = next;
    }

    pub fn applyPendingRuntimeEvents(self: *SyslinkHost, runtime: *core.FrontendRuntime) frontend_core.RuntimeEventApplyResult {
        if (self.current_view) |*view| {
            return frontend_core.applyPendingRuntimeEvents(view, runtime);
        }
        return .{};
    }
};

test "SyslinkHost advertises remote transport capabilities" {
    const caps = SyslinkHost.capabilities();

    try std.testing.expectEqual(@as(@TypeOf(caps.frontend_kind), .desktop), caps.frontend_kind);
    try std.testing.expect(caps.cell_render);
    try std.testing.expect(caps.reconnect);
    try std.testing.expect(caps.remote_transport);
}

test "SyslinkHost maps remote close and transport loss differently" {
    const closed = SyslinkHost.mapRemoteEvent(.remote_closed);
    const lost = SyslinkHost.mapRemoteEvent(.transport_lost);

    try std.testing.expect(std.meta.activeTag(closed) == .close_requested);
    try std.testing.expect(std.meta.activeTag(lost) == .connection_lost);
    try std.testing.expectEqual(frontend_core.DisconnectReason.transport_lost, lost.connection_lost);
}

test "SyslinkHost maps remote terminal bytes into frontend-neutral input" {
    const input = "\x1b[A";
    const event = SyslinkHost.mapRemoteEvent(.{ .terminal_bytes = input });

    try std.testing.expectEqualStrings(input, event.input_bytes);
}

test "SyslinkHost applies remote session snapshots into shared view" {
    const allocator = std.testing.allocator;
    var host = SyslinkHost.init(allocator);
    defer host.deinit();

    const json =
        \\{"version":1,"uuid":"ssssssssssssssssssssssssssssssss","session_name":"remote","base_root":"/srv/work","tab_counter":1,"active_tab":0,"active_float_uuid":null,"focused_pane_uuid":null,"tabs":[],"panes":[],"floats":[]}
    ;
    try host.applySessionStateJson(json);

    try std.testing.expect(host.current_view != null);
    try std.testing.expectEqualStrings("remote", host.current_view.?.session_name);
    try std.testing.expectEqualStrings("/srv/work", host.current_view.?.base_root.?);
}
