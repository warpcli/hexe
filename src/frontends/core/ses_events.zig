const core = @import("core");

const ctl_payloads = @import("ctl_payloads.zig");
const view_model = @import("view_model.zig");

/// Apply queued SES/runtime side-channel events to a frontend-neutral view.
///
/// Concrete hosts should call this before rendering/diffing their presentation
/// state. Terminal can keep its existing pane mirroring during migration, while
/// web/syslink can rely on this shared path directly.
pub fn applyPendingRuntimeEvents(
    view: *view_model.SessionView,
    runtime: *core.FrontendRuntime,
) view_model.RuntimeEventApplyResult {
    return view.applyPendingRuntimeEvents(runtime);
}

/// Apply a shared pane-CWD CTL payload to the frontend-neutral view model.
pub fn applyPaneCwdPayload(
    view: *view_model.SessionView,
    payload: ctl_payloads.PaneCwdPayload,
) !void {
    try view.applyPaneShell(payload.uuid, .{ .cwd = payload.cwd });
}

/// Apply the frontend-neutral parts of a pane-info CTL payload to the shared
/// view model.
pub fn applyPaneInfoPayload(
    view: *view_model.SessionView,
    payload: ctl_payloads.PaneInfoPayload,
) !void {
    var applied = false;
    if (payload.name) |name| {
        try view.applyPaneName(payload.uuid, name);
        applied = true;
    }
    if (payload.fg_name != null or payload.fg_pid != null) {
        try view.applyPaneProc(payload.uuid, .{
            .name = payload.fg_name,
            .pid = payload.fg_pid,
        });
        applied = true;
    }
    if (!applied) return error.NoPaneInfoFields;
}

/// Apply a forwarded shell lifecycle payload to the frontend-neutral view model.
pub fn applyShellEventPayload(
    view: *view_model.SessionView,
    payload: ctl_payloads.ShellEventPayload,
) !void {
    try view.applyPaneShell(payload.uuid, .{
        .cmd = payload.cmd,
        .cwd = payload.cwd,
        .status = payload.status,
        .duration_ms = payload.duration_ms,
        .jobs = payload.jobs,
        .running = payload.running,
        .started_at_ms = payload.started_at_ms,
    });
}

/// Apply a pane-exited payload to the frontend-neutral view model.
pub fn applyPaneExitedPayload(
    view: *view_model.SessionView,
    payload: ctl_payloads.PaneUuidPayload,
) !void {
    try view.applyPaneExited(payload.uuid);
}

test "RuntimeEventApplyResult reports whether anything changed" {
    const testing = @import("std").testing;
    try testing.expect(!(view_model.RuntimeEventApplyResult{}).changed());
    try testing.expect((view_model.RuntimeEventApplyResult{ .cwd_updates = 1 }).changed());
}

test "shared CTL payload application updates SessionView" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const session_model = core.session_model;

    var snapshot = try session_model.SessionSnapshot.initMinimal(allocator, [_]u8{'s'} ** 32, "alpha");
    defer snapshot.deinit();
    try snapshot.panes.put([_]u8{'p'} ** 32, .{
        .uuid = [_]u8{'p'} ** 32,
        .kind = .split,
    });

    var view = try view_model.SessionView.fromSnapshot(allocator, &snapshot);
    defer view.deinit();

    var cwd_payload = ctl_payloads.PaneCwdPayload{
        .uuid = [_]u8{'p'} ** 32,
        .cwd = try allocator.dupe(u8, "/tmp/hexe"),
    };
    defer cwd_payload.deinit(allocator);
    try applyPaneCwdPayload(&view, cwd_payload);

    var info_payload = ctl_payloads.PaneInfoPayload{
        .uuid = [_]u8{'p'} ** 32,
        .name = try allocator.dupe(u8, "editor"),
        .fg_name = try allocator.dupe(u8, "nvim"),
        .fg_pid = 44,
    };
    defer info_payload.deinit(allocator);
    try applyPaneInfoPayload(&view, info_payload);

    var shell_payload = ctl_payloads.ShellEventPayload{
        .uuid = [_]u8{'p'} ** 32,
        .phase_start = false,
        .status = 0,
        .duration_ms = 12,
        .started_at_ms = 2,
        .jobs = 1,
        .running = false,
        .cmd = try allocator.dupe(u8, "make test"),
    };
    defer shell_payload.deinit(allocator);
    try applyShellEventPayload(&view, shell_payload);

    try applyPaneExitedPayload(&view, .{ .uuid = [_]u8{'p'} ** 32 });

    const pane = view.findPane([_]u8{'p'} ** 32).?;
    try std.testing.expectEqualStrings("/tmp/hexe", pane.shell_cwd.?);
    try std.testing.expectEqualStrings("editor", pane.name.?);
    try std.testing.expectEqualStrings("nvim", pane.proc_name.?);
    try std.testing.expectEqual(@as(?i32, 44), pane.proc_pid);
    try std.testing.expectEqualStrings("make test", pane.shell_cmd.?);
    try std.testing.expectEqual(@as(?i32, 0), pane.shell_status);
    try std.testing.expect(pane.exited);
}
