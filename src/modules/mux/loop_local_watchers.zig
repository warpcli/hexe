const std = @import("std");
const posix = std.posix;
const xev = @import("xev").Dynamic;

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

pub const LocalPaneSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    pending_dead_splits: *std.ArrayList(u16),
    pending_remove_fds: *std.ArrayList(posix.fd_t),
};

pub const LocalPaneWatcher = struct {
    completion: xev.Completion = .{},
    slot: LocalPaneSlot,
};

pub const FloatPaneSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    pending_dead_float_uuids: *std.ArrayList([32]u8),
    pending_remove_fds: *std.ArrayList(posix.fd_t),
};

pub const FloatPaneWatcher = struct {
    completion: xev.Completion = .{},
    slot: FloatPaneSlot,
};

pub fn queueFd(list: *std.ArrayList(posix.fd_t), fd: posix.fd_t, allocator: std.mem.Allocator) void {
    for (list.items) |v| {
        if (v == fd) return;
    }
    list.append(allocator, fd) catch {};
}

pub fn fdListContains(fds: []const posix.fd_t, fd: posix.fd_t) bool {
    for (fds) |v| {
        if (v == fd) return true;
    }
    return false;
}

pub fn findLocalSplitPaneByFd(state: *State, fd: posix.fd_t) ?*Pane {
    var pane_it = state.currentLayout().splitIterator();
    while (pane_it.next()) |pane| {
        if (pane.*.hasPollableFd() and pane.*.getFd() == fd) return pane.*;
    }
    return null;
}

pub fn findFloatByFd(state: *State, fd: posix.fd_t) ?*Pane {
    for (state.floats.items) |pane| {
        if (pane.hasPollableFd() and pane.getFd() == fd) return pane;
    }
    return null;
}

pub fn localPaneCallback(
    ctx: ?*LocalPaneSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        if (findLocalSplitPaneByFd(slot.state, slot.fd)) |pane| {
            slot.pending_dead_splits.append(slot.state.allocator, pane.id) catch {};
        }
        queueFd(slot.pending_remove_fds, slot.fd, slot.state.allocator);
        return .disarm;
    };

    const pane = findLocalSplitPaneByFd(slot.state, slot.fd) orelse {
        queueFd(slot.pending_remove_fds, slot.fd, slot.state.allocator);
        return .disarm;
    };

    if (pane.poll(slot.buffer)) |had_data| {
        if (had_data) {
            pane.vt.invalidateRenderState();
            slot.state.needs_render = true;
        }
        if (pane.takeOscExpectResponse()) {
            slot.state.osc_reply_target_uuid = pane.uuid;
        }
        if (pane.did_clear) {
            slot.state.force_full_render = true;
            slot.state.renderer.invalidate();
        }
    } else |_| {}

    if (!pane.isAlive()) {
        slot.pending_dead_splits.append(slot.state.allocator, pane.id) catch {};
        queueFd(slot.pending_remove_fds, slot.fd, slot.state.allocator);
        return .disarm;
    }

    return .rearm;
}

fn queueDeadFloatUuid(list: *std.ArrayList([32]u8), uuid: [32]u8, allocator: std.mem.Allocator) void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, &existing, &uuid)) return;
    }
    list.append(allocator, uuid) catch {};
}

pub fn floatPaneCallback(
    ctx: ?*FloatPaneSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        if (findFloatByFd(slot.state, slot.fd)) |pane| {
            queueDeadFloatUuid(slot.pending_dead_float_uuids, pane.uuid, slot.state.allocator);
        }
        queueFd(slot.pending_remove_fds, slot.fd, slot.state.allocator);
        return .disarm;
    };

    const pane = findFloatByFd(slot.state, slot.fd) orelse {
        queueFd(slot.pending_remove_fds, slot.fd, slot.state.allocator);
        return .disarm;
    };

    if (pane.poll(slot.buffer)) |had_data| {
        if (had_data) {
            pane.vt.invalidateRenderState();
            slot.state.needs_render = true;
        }
        if (pane.takeOscExpectResponse()) {
            slot.state.osc_reply_target_uuid = pane.uuid;
        }
        if (pane.did_clear) {
            slot.state.force_full_render = true;
            slot.state.renderer.invalidate();
        }
    } else |_| {}

    if (!pane.isAlive()) {
        queueDeadFloatUuid(slot.pending_dead_float_uuids, pane.uuid, slot.state.allocator);
        queueFd(slot.pending_remove_fds, slot.fd, slot.state.allocator);
        return .disarm;
    }

    return .rearm;
}
