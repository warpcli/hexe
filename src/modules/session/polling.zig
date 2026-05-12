const std = @import("std");
const posix = std.posix;

/// Event-loop scratch: fds the poll set needs to add/remove between ticks.
pub const PollingState = struct {
    pending_poll_fds: std.ArrayList(posix.fd_t) = .empty,
    pending_remove_poll_fds: std.ArrayList(posix.fd_t) = .empty,

    pub fn deinit(self: *PollingState, allocator: std.mem.Allocator) void {
        self.pending_poll_fds.deinit(allocator);
        self.pending_remove_poll_fds.deinit(allocator);
    }
};
