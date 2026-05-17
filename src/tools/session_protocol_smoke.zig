const std = @import("std");
const core = @import("core");

const frontend_client = core.frontend_client;

fn expect(ok: bool, msg: []const u8) !void {
    if (!ok) {
        std.debug.print("session protocol smoke failed: {s}\n", .{msg});
        return error.SmokeFailed;
    }
}

fn sessionId(comptime digit: u8) [32]u8 {
    return [_]u8{digit} ** 32;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_session = sessionId('1');
    const reattach_session = sessionId('2');
    const tab_uuid = sessionId('a');

    var first = frontend_client.SesClient.initLocalIpc(
        allocator,
        original_session,
        "protocol-smoke",
        true,
        null,
        null,
        .terminal,
    );
    try first.connect();

    const pane = try first.createPane("/bin/sh", "/tmp", null, null, null, null, null);
    try first.sessionAddTab(tab_uuid, pane.uuid, 0, "main");
    try first.detachSession(original_session);
    first.deinit();

    var second = frontend_client.SesClient.initLocalIpc(
        allocator,
        reattach_session,
        "protocol-smoke-reattach",
        true,
        null,
        null,
        .terminal,
    );
    defer second.deinit();
    try second.connect();

    var reattached = (try second.reattachSession(original_session[0..8])) orelse {
        std.debug.print("session protocol smoke failed: detached session not found\n", .{});
        return error.SmokeFailed;
    };
    defer {
        allocator.free(reattached.session_state_json);
        allocator.free(reattached.pane_uuids);
    }

    try expect(reattached.pane_uuids.len == 1, "reattach returned wrong pane count");
    try expect(std.mem.eql(u8, &reattached.pane_uuids[0], &pane.uuid), "reattach returned wrong pane uuid");

    _ = try second.adoptPane(pane.uuid);
    try second.updateSession(original_session, "protocol-smoke");

    var detached_sessions: [8]frontend_client.DetachedSessionInfo = undefined;
    const detached_count = try second.listSessions(&detached_sessions);
    for (detached_sessions[0..detached_count]) |detached| {
        try expect(!std.mem.eql(u8, &detached.session_id, &original_session), "detached session remained after commit registration");
    }

    std.debug.print("session protocol smoke ok: pane={s}\n", .{pane.uuid[0..8]});
}
