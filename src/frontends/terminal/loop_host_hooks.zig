const std = @import("std");
const posix = std.posix;
const frontend_core = @import("frontend_core");

const State = @import("state.zig").State;

/// Terminal-host operations required by the shared terminal event loop.
///
/// The loop drives timers and session/runtime upkeep, while the concrete host
/// owns surface-specific behavior such as input reads, resize probing, terminal
/// cleanup, and rendering.
pub const HostHooks = struct {
    connectionLost: *const fn (*State) void,
    finalizeCapabilities: *const fn (*State, i64) void,
    handleInput: *const fn (*State, []const u8) void,
    handleStopRequest: *const fn (*State, frontend_core.StopRequest) void,
    pollResize: *const fn (*State) void,
    readInput: *const fn (posix.fd_t, []u8) anyerror!usize,
    renderIfDue: *const fn (*State, *i64) void,
    stdin_fd: posix.fd_t,
};
