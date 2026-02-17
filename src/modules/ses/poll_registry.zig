const std = @import("std");
const posix = std.posix;

pub fn reconcile(
    allocator: std.mem.Allocator,
    poll_fds: *std.ArrayList(posix.pollfd),
    remove_fds: []const posix.fd_t,
    add_fds: []const posix.fd_t,
) void {
    for (remove_fds) |old_fd| {
        var idx: usize = 1;
        while (idx < poll_fds.items.len) {
            if (poll_fds.items[idx].fd == old_fd) {
                _ = poll_fds.orderedRemove(idx);
                break;
            }
            idx += 1;
        }
    }

    for (add_fds) |new_fd| {
        poll_fds.append(allocator, .{
            .fd = new_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }) catch {};
    }
}

pub fn resetRevents(poll_fds: *std.ArrayList(posix.pollfd)) void {
    for (poll_fds.items) |*pfd| {
        pfd.revents = 0;
    }
}
