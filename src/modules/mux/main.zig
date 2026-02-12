const std = @import("std");
const posix = std.posix;
const core = @import("core");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const ses_client = @import("ses_client.zig");
const SesClient = ses_client.SesClient;

const State = @import("state.zig").State;
const loop_core = @import("loop_core.zig");

var debug_enabled: bool = false;

/// Global state pointer for signal handlers.
var global_state: std.atomic.Value(?*State) = std.atomic.Value(?*State).init(null);

/// SIGHUP handler: set detach mode and stop the main loop.
/// This is called when the terminal closes unexpectedly.
fn sighupHandler(_: c_int) callconv(.c) void {
    if (global_state.load(.acquire)) |state| {
        state.detach_mode = true;

        // If reattach is in progress, give it time to complete (up to 5 seconds)
        if (state.reattach_in_progress.load(.acquire)) {
            var i: usize = 0;
            while (i < 50 and state.reattach_in_progress.load(.acquire)) : (i += 1) {
                // Sleep 100ms between checks (total max 5 seconds)
                std.Thread.sleep(100 * std.time.ns_per_ms);
            }
        }

        state.running = false;
    }
}

/// SIGTERM/SIGINT handler: gracefully stop the main loop.
/// This allows the defer cleanup to run (disable kitty keyboard protocol, etc.).
fn sigtermHandler(_: c_int) callconv(.c) void {
    if (global_state.load(.acquire)) |state| {
        state.running = false;
    }
}

pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    std.debug.print("[mux] " ++ fmt ++ "\n", args);
}

/// Arguments for mux commands.
pub const MuxArgs = struct {
    name: ?[]const u8 = null,
    attach: ?[]const u8 = null,
    notify_message: ?[]const u8 = null,
    list: bool = false,
    debug: bool = false,
    log_file: ?[]const u8 = null,
};

/// Entry point for mux - can be called directly from unified CLI.
pub fn run(mux_args: MuxArgs) !void {
    const allocator = std.heap.page_allocator;

    // Handle --notify: send to parent mux and exit.
    if (mux_args.notify_message) |msg| {
        sendNotifyToParentMux(allocator, msg);
        return;
    }

    // Handle --list: show detached sessions and orphaned panes.
    if (mux_args.list) {
        const tmp_uuid = core.ipc.generateUuid();
        const tmp_name = core.ipc.generateSessionName();
        var ses = SesClient.init(allocator, tmp_uuid, tmp_name, false, false, null); // keepalive=false for temp connection
        defer ses.deinit();
        ses.connect() catch {
            std.debug.print("Could not connect to ses daemon\n", .{});
            return;
        };

        // List detached sessions.
        var sessions: [16]ses_client.DetachedSessionInfo = undefined;
        const sess_count = ses.listSessions(&sessions) catch 0;
        if (sess_count > 0) {
            std.debug.print("Detached sessions (attach by name or UUID prefix):\n", .{});
            const instance = std.posix.getenv("HEXE_INSTANCE");
            for (sessions[0..sess_count]) |s| {
                const name = s.session_name[0..s.session_name_len];
                const uuid_prefix = s.session_id[0..8];
                if (instance) |inst| {
                    if (inst.len > 0) {
                        std.debug.print("  [{s}] {s:<12} ({d} tabs)\n", .{ uuid_prefix, name, s.pane_count });
                        std.debug.print("    → hexe mux attach --instance {s} {s}\n", .{ inst, uuid_prefix });
                    } else {
                        std.debug.print("  [{s}] {s:<12} ({d} tabs)\n", .{ uuid_prefix, name, s.pane_count });
                        std.debug.print("    → hexe mux attach {s}\n", .{uuid_prefix});
                    }
                } else {
                    std.debug.print("  [{s}] {s:<12} ({d} tabs)\n", .{ uuid_prefix, name, s.pane_count });
                    std.debug.print("    → hexe mux attach {s}\n", .{uuid_prefix});
                }
            }
        }

        // List orphaned panes.
        var tabs: [32]ses_client.OrphanedPaneInfo = undefined;
        const count = ses.listOrphanedPanes(&tabs) catch 0;
        if (count > 0) {
            std.debug.print("Orphaned tabs (disowned):\n", .{});
            for (tabs[0..count]) |p| {
                std.debug.print("  [{s}] pid={d}\n", .{ p.uuid[0..8], p.pid });
            }
        }

        if (sess_count == 0 and count == 0) {
            std.debug.print("No detached sessions or orphaned panes\n", .{});
        }
        return;
    }

    // Handle --attach: attach to detached session by name or UUID prefix.
    if (mux_args.attach) |uuid_arg| {
        if (uuid_arg.len < 3) {
            std.debug.print("Session name/UUID too short (need at least 3 chars)\n", .{});
            return;
        }
        // Will be handled after state init.
    }

    // Ignore SIGPIPE so writes to disconnected pod sockets return EPIPE
    // instead of killing the mux process.
    const sigpipe_action = std.os.linux.Sigaction{
        .handler = .{ .handler = std.os.linux.SIG.IGN },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.PIPE, &sigpipe_action, null);

    // Handle SIGHUP: terminal closed unexpectedly - preserve session for reattach.
    const sighup_action = std.os.linux.Sigaction{
        .handler = .{ .handler = sighupHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.HUP, &sighup_action, null);

    // Handle SIGTERM/SIGINT: graceful shutdown (allows cleanup to run).
    const sigterm_action = std.os.linux.Sigaction{
        .handler = .{ .handler = sigtermHandler },
        .mask = std.os.linux.sigemptyset(),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(posix.SIG.TERM, &sigterm_action, null);
    _ = std.os.linux.sigaction(posix.SIG.INT, &sigterm_action, null);

    // Redirect stderr to a log file or /dev/null to avoid display corruption.
    // When --debug is set without --logfile, default to instance-specific log.
    var default_log_path: ?[]const u8 = null;
    defer if (default_log_path) |p| allocator.free(p);

    const effective_log: ?[]const u8 = if (mux_args.log_file) |p|
        (if (p.len > 0) p else null)
    else if (mux_args.debug) blk: {
        default_log_path = core.ipc.getLogPath(allocator) catch null;
        break :blk default_log_path;
    } else null;
    redirectStderr(effective_log);
    debug_enabled = mux_args.debug;
    debugLog("started", .{});

    // Get terminal size.
    const size = terminal.getTermSize();

    // Initialize state.
    var state = try State.init(allocator, size.cols, size.rows, mux_args.debug, mux_args.log_file);
    defer state.deinit();

    // Register state for signal handlers.
    global_state.store(&state, .release);
    defer global_state.store(null, .release);

    // Show notification for config status.
    switch (state.config.status) {
        .missing => state.notifications.showFor("Config not found (~/.config/hexe/mux.lua), using defaults", 5000),
        .@"error" => {
            if (state.config.status_message) |msg| {
                const err_msg = std.fmt.allocPrint(allocator, "Config error: {s}", .{msg}) catch null;
                if (err_msg) |m| {
                    state.notifications.showFor(m, 8000);
                    allocator.free(m);
                } else {
                    state.notifications.showFor("Config error, using defaults", 5000);
                }
            } else {
                state.notifications.showFor("Config error, using defaults", 5000);
            }
        },
        .loaded => {},
    }

    // Set custom session name if provided.
    if (mux_args.name) |custom_name| {
        const duped = allocator.dupe(u8, custom_name) catch null;
        if (duped) |d| {
            state.session_name = d;
            state.session_name_owned = d;
        }
    }

    // Set HEXE_MUX_SOCKET as a flag for shell integrations.
    _ = c.setenv("HEXE_MUX_SOCKET", "1", 1);

    // Connect to ses daemon FIRST (start it if needed).
    state.ses_client.connect() catch |e| {
        debugLog("ses connect failed: {s}", .{@errorName(e)});
    };
    debugLog("ses connected (started={})", .{state.ses_client.just_started_daemon});

    // If server resolved to a different name (collision avoidance), update state.
    if (state.ses_client.resolved_name) |resolved| {
        if (!std.mem.eql(u8, resolved, state.session_name)) {
            debugLog("session name resolved from '{s}' to '{s}'", .{ state.session_name, resolved });

            // Notify user about name collision
            const msg = std.fmt.allocPrint(
                allocator,
                "Session name changed: '{s}' -> '{s}' (collision)",
                .{ state.session_name, resolved },
            ) catch null;
            if (msg) |m| {
                state.notifications.showFor(m, 4000);
                allocator.free(m);
            }

            // Free old owned name if any
            if (state.session_name_owned) |old| {
                allocator.free(old);
            }
            // Duplicate and store the resolved name
            const duped = allocator.dupe(u8, resolved) catch null;
            if (duped) |d| {
                state.session_name = d;
                state.session_name_owned = d;
            }
        }
    }

    // Show notification if we just started the daemon.
    if (state.ses_client.just_started_daemon) {
        state.notifications.showFor("ses daemon started", 2000);
    }

    // Export session ID so child panes can identify their parent mux.
    // Must happen BEFORE createTab/reattach which fork pane shells.
    var session_id_z: [33]u8 = undefined;
    @memcpy(session_id_z[0..32], &state.uuid);
    session_id_z[32] = 0;
    _ = c.setenv("HEXE_SESSION", &session_id_z, 1);

    // Handle --attach: try session first, then orphaned pane.
    if (mux_args.attach) |uuid_prefix| {
        debugLog("attach: trying to reattach with prefix={s}", .{uuid_prefix});
        std.debug.print("[mux] ATTACH: starting reattach for '{s}'\n", .{uuid_prefix});
        if (state.reattachSession(uuid_prefix)) {
            debugLog("attach: reattachSession succeeded", .{});
            std.debug.print("[mux] ATTACH: reattachSession returned TRUE, tabs={d}\n", .{state.tabs.items.len});
            state.notifications.show("Session reattached");
            // Reattach may change state.uuid — update env for subsequent panes.
            @memcpy(session_id_z[0..32], &state.uuid);
            _ = c.setenv("HEXE_SESSION", &session_id_z, 1);
        } else if (state.attachOrphanedPane(uuid_prefix)) {
            debugLog("attach: attachOrphanedPane succeeded", .{});
            std.debug.print("[mux] ATTACH: reattachSession FALSE, attachOrphanedPane TRUE\n", .{});
            state.notifications.show("Attached to orphaned pane");
        } else {
            // Session/pane not found - EXIT with error, don't create new session
            debugLog("attach: both reattach methods failed, exiting", .{});
            std.debug.print("Session or pane '{s}' not found\n", .{uuid_prefix});
            std.debug.print("Use 'hexe mux list' to see available sessions\n", .{});
            return; // Exit without entering main loop
        }
    } else {
        // Create first tab with one pane (will use ses if connected).
        try state.createTab();
    }

    // Auto-adopt sticky panes from ses for this directory.
    std.debug.print("[mux] ATTACH: calling adoptStickyPanes\n", .{});
    state.adoptStickyPanes();

    // Continue with main loop.
    std.debug.print("[mux] ATTACH: entering main loop\n", .{});
    try loop_core.runMainLoop(&state);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mux_args = MuxArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) and i + 1 < args.len) {
            i += 1;
            mux_args.notify_message = args[i];
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            mux_args.list = true;
        } else if ((std.mem.eql(u8, arg, "--attach") or std.mem.eql(u8, arg, "-a")) and i + 1 < args.len) {
            i += 1;
            mux_args.attach = args[i];
        } else if ((std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-N")) and i + 1 < args.len) {
            i += 1;
            mux_args.name = args[i];
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            mux_args.debug = true;
        } else if ((std.mem.eql(u8, arg, "--logfile") or std.mem.eql(u8, arg, "-L")) and i + 1 < args.len) {
            i += 1;
            mux_args.log_file = args[i];
        }
    }

    try run(mux_args);
}

fn redirectStderr(log_file: ?[]const u8) void {
    var redirected = false;
    if (log_file) |path| {
        if (path.len > 0) {
            const logfd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch null;
            if (logfd) |fd| {
                posix.dup2(fd, posix.STDERR_FILENO) catch {};
                if (fd > 2) posix.close(fd);
                redirected = true;
            }
        }
    }

    if (redirected) return;

    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    posix.dup2(devnull.handle, posix.STDERR_FILENO) catch {};
    devnull.close();
}

fn sendNotifyToParentMux(allocator: std.mem.Allocator, message: []const u8) void {
    const wire = core.wire;

    const ses_path = core.ipc.getSesSocketPath(allocator) catch return;
    defer allocator.free(ses_path);

    var client = core.ipc.Client.connect(ses_path) catch return;
    defer client.close();
    const fd = client.fd;

    // CLI handshake + notify message.
    _ = posix.write(fd, &.{wire.SES_HANDSHAKE_CLI}) catch return;
    const notify = wire.Notify{ .msg_len = @intCast(message.len) };
    wire.writeControlWithTrail(fd, .notify, std.mem.asBytes(&notify), message) catch {};
}
