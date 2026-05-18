const std = @import("std");
const posix = std.posix;
const core = @import("core");
const ses = @import("main.zig");
const store_mod = @import("store.zig");

pub fn isPidAlive(pid: posix.pid_t) bool {
    if (pid <= 0) return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch |err| {
        core.logging.logError("ses", "failed to format sticky pane pid stat path", err);
        return false;
    };
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err != error.FileNotFound) {
            core.logging.logError("ses", "failed to open sticky pane pid stat", err);
        }
        return false;
    };
    file.close();
    return true;
}

pub fn findStickyPane(store: *store_mod.SessionStore, pwd: []const u8, key: u8) ?*store_mod.Pane {
    return findStickyPaneWithAffinity(store, pwd, key, null);
}

pub fn findStickyPaneWithAffinity(
    store: *store_mod.SessionStore,
    pwd: []const u8,
    key: u8,
    preferred_session_name: ?[]const u8,
) ?*store_mod.Pane {
    var fallback_pane: ?*store_mod.Pane = null;

    var iter = store.panes.valueIterator();
    while (iter.next()) |pane| {
        // Sticky candidates can be idle (.sticky), currently active
        // (.attached), or parked inside a detached session (.detached).
        // Per-CWD sticky floats are globally keyed by pwd+key, so launching
        // one after reattach must reuse the existing detached pod instead of
        // spawning a duplicate just because it is not currently attached.
        if (pane.state == .sticky or pane.state == .attached or pane.state == .detached) {
            if (!isPidAlive(pane.child_pid)) continue;
            if (pane.sticky_pwd) |spwd| {
                if (pane.sticky_key) |skey| {
                    if (skey == key and std.mem.eql(u8, spwd, pwd)) {
                        if (preferred_session_name) |psn| {
                            if (pane.sticky_session_name) |ssn| {
                                if (std.mem.eql(u8, ssn, psn)) {
                                    ses.debugLog("findStickyPane: affinity match (session={s})", .{psn});
                                    return pane;
                                }
                            }
                        }
                        if (fallback_pane == null) {
                            fallback_pane = pane;
                        }
                    }
                }
            }
        }
    }

    if (fallback_pane != null) {
        if (preferred_session_name) |psn| {
            ses.debugLog("findStickyPane: using fallback (preferred={s})", .{psn});
        }
    }
    return fallback_pane;
}
