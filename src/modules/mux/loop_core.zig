const std = @import("std");
const posix = std.posix;
const core = @import("core");
const wire = core.wire;
const pod_protocol = core.pod_protocol;
const xev = @import("xev").Dynamic;

const terminal = @import("terminal.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const SesClient = @import("ses_client.zig").SesClient;
const helpers = @import("helpers.zig");

const mux = @import("main.zig");
const loop_input = @import("loop_input.zig");
const loop_ipc = @import("loop_ipc.zig");
const loop_render = @import("loop_render.zig");
const float_completion = @import("float_completion.zig");
const keybinds = @import("keybinds.zig");

const LoopTimerContext = struct {
    state: *State,
    last_pane_sync: i64,
    last_heartbeat: i64,
    pane_sync_interval: i64,
    heartbeat_interval: i64,
};

fn loopTimerCallback(
    ctx: ?*LoopTimerContext,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const timer_ctx = ctx orelse return .disarm;
    _ = result catch return .rearm;

    const now = std.time.milliTimestamp();
    if (now - timer_ctx.last_pane_sync >= timer_ctx.pane_sync_interval) {
        timer_ctx.last_pane_sync = now;
        timer_ctx.state.syncFocusedPaneInfo();
    }
    if (now - timer_ctx.last_heartbeat >= timer_ctx.heartbeat_interval) {
        timer_ctx.last_heartbeat = now;
        _ = timer_ctx.state.ses_client.sendPing();
    }

    return .rearm;
}

const SesVtSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    watched_fd: *?posix.fd_t,
};

const SesVtWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: SesVtSlot = undefined,
    watched_fd: ?posix.fd_t = null,
};

const SesCtlSlot = struct {
    state: *State,
    fd: posix.fd_t,
    buffer: []u8,
    watched_fd: *?posix.fd_t,
};

const SesCtlWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: SesCtlSlot = undefined,
    watched_fd: ?posix.fd_t = null,
};

const StdinSlot = struct {
    state: *State,
    buffer: []u8,
};

const StdinWatcher = struct {
    loop: *xev.Loop,
    completion: xev.Completion = .{},
    slot: StdinSlot = undefined,
    armed: bool = false,
};

fn ensureSesVtWatcherArmed(state: *State, watcher: *SesVtWatcher, buffer: []u8) void {
    if (watcher.watched_fd != null) return;
    const vt_fd = state.ses_client.getVtFd() orelse return;

    watcher.watched_fd = vt_fd;
    watcher.slot = .{ .state = state, .fd = vt_fd, .buffer = buffer, .watched_fd = &watcher.watched_fd };
    const file = xev.File.initFd(vt_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, SesVtSlot, &watcher.slot, sesVtCallback);
}

fn ensureSesCtlWatcherArmed(state: *State, watcher: *SesCtlWatcher, buffer: []u8) void {
    if (watcher.watched_fd != null) return;
    const ctl_fd = state.ses_client.getCtlFd() orelse return;

    watcher.watched_fd = ctl_fd;
    watcher.slot = .{ .state = state, .fd = ctl_fd, .buffer = buffer, .watched_fd = &watcher.watched_fd };
    const file = xev.File.initFd(ctl_fd);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, SesCtlSlot, &watcher.slot, sesCtlCallback);
}

fn sesVtCallback(
    ctx: ?*SesVtSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        if (slot.state.ses_client.vt_fd) |vt_fd| {
            if (vt_fd == slot.fd) {
                posix.close(vt_fd);
                slot.state.ses_client.vt_fd = null;
                slot.state.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
            }
        }
        return .disarm;
    };

    const vt_fd = slot.state.ses_client.getVtFd() orelse {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    };
    if (vt_fd != slot.fd) {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    }

    var vt_frames: usize = 0;
    while (vt_frames < 64) : (vt_frames += 1) {
        const hdr = wire.tryReadMuxVtHeader(vt_fd) catch |err| switch (err) {
            error.WouldBlock => break,
            else => {
                if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
                if (slot.state.ses_client.vt_fd) |live_fd| {
                    if (live_fd == slot.fd) {
                        posix.close(live_fd);
                        slot.state.ses_client.vt_fd = null;
                        slot.state.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
                    }
                }
                return .disarm;
            },
        };
        if (hdr.len > slot.buffer.len) {
            var remaining: usize = hdr.len;
            while (remaining > 0) {
                const chunk = @min(remaining, slot.buffer.len);
                wire.readExact(vt_fd, slot.buffer[0..chunk]) catch break;
                remaining -= chunk;
            }
            continue;
        }
        if (hdr.len > 0) {
            wire.readExact(vt_fd, slot.buffer[0..hdr.len]) catch {
                if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
                if (slot.state.ses_client.vt_fd) |live_fd| {
                    if (live_fd == slot.fd) {
                        posix.close(live_fd);
                        slot.state.ses_client.vt_fd = null;
                        slot.state.notifications.showFor("Warning: Lost connection to ses daemon (VT channel) - panes frozen", 5000);
                    }
                }
                return .disarm;
            };
        }

        if (slot.state.findPaneByPaneId(hdr.pane_id)) |pane| {
            if (hdr.frame_type == @intFromEnum(pod_protocol.FrameType.output)) {
                mux.debugLog("vt recv: pane_id={d} output len={d}", .{ hdr.pane_id, hdr.len });
                pane.feedPodOutput(slot.buffer[0..hdr.len]);
                pane.vt.invalidateRenderState();
                slot.state.needs_render = true;
            } else if (hdr.frame_type == @intFromEnum(pod_protocol.FrameType.backlog_end)) {
                mux.debugLog("vt recv: pane_id={d} backlog_end", .{hdr.pane_id});
                pane.vt.invalidateRenderState();
                slot.state.needs_render = true;
                slot.state.force_full_render = true;
            }
        } else {
            mux.debugLog("vt recv: unknown pane_id={d}", .{hdr.pane_id});
        }
    }

    return .rearm;
}

fn sesCtlCallback(
    ctx: ?*SesCtlSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        if (slot.state.ses_client.ctl_fd) |ctl_fd| {
            if (ctl_fd == slot.fd) {
                posix.close(ctl_fd);
                slot.state.ses_client.ctl_fd = null;
                slot.state.notifications.showFor("Warning: Lost connection to ses daemon (CTL channel)", 5000);
            }
        }
        return .disarm;
    };

    const ctl_fd = slot.state.ses_client.getCtlFd() orelse {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    };
    if (ctl_fd != slot.fd) {
        if (slot.watched_fd.* == slot.fd) slot.watched_fd.* = null;
        return .disarm;
    }

    loop_ipc.handleSesMessage(slot.state, slot.buffer);
    return .rearm;
}

fn ensureStdinWatcherArmed(state: *State, watcher: *StdinWatcher, buffer: []u8) void {
    if (watcher.armed) return;
    watcher.slot = .{ .state = state, .buffer = buffer };
    const file = xev.File.initFd(posix.STDIN_FILENO);
    watcher.completion = .{};
    file.poll(watcher.loop, &watcher.completion, .read, StdinSlot, &watcher.slot, stdinCallback);
    watcher.armed = true;
}

fn stdinCallback(
    ctx: ?*StdinSlot,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.File,
    result: xev.PollError!xev.PollEvent,
) xev.CallbackAction {
    const slot = ctx orelse return .disarm;
    _ = result catch {
        slot.state.detach_mode = true;
        slot.state.running = false;
        return .disarm;
    };

    const n = posix.read(posix.STDIN_FILENO, slot.buffer) catch {
        slot.state.detach_mode = true;
        slot.state.running = false;
        return .disarm;
    };
    if (n == 0) {
        slot.state.detach_mode = true;
        slot.state.running = false;
        return .disarm;
    }

    loop_input.handleInput(slot.state, slot.buffer[0..n]);
    return .rearm;
}

pub fn runMainLoop(state: *State) !void {
    const allocator = state.allocator;

    try xev.detect();
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var loop_timer = try xev.Timer.init();
    defer loop_timer.deinit();

    // Enter raw mode.
    const orig_termios = try terminal.enableRawMode(posix.STDIN_FILENO);
    defer terminal.disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen and reset it.
    const stdout = std.fs.File.stdout();
    // Enable: altscreen, hide cursor, mouse tracking (1000/1002/1006), bracketed paste (2004),
    // kitty keyboard protocol (>3u with flags: 1=disambiguate + 2=report event types)
    try stdout.writeAll("\x1b[?1049h\x1b[2J\x1b[3J\x1b[H\x1b[0m\x1b(B\x1b)0\x0f\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[>3u");
    defer stdout.writeAll("\x1b[<u\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    // Build poll fds (dynamic to support unlimited panes).
    var poll_fds: std.ArrayList(posix.pollfd) = .empty;
    defer poll_fds.deinit(allocator);
    var buffer: [1024 * 1024]u8 = undefined; // Larger buffer for efficiency
    var ses_vt_buffer: [1024 * 1024]u8 = undefined;
    var ses_ctl_buffer: [1024 * 1024]u8 = undefined;
    var stdin_buffer: [64 * 1024]u8 = undefined;

    var ses_vt_watcher: SesVtWatcher = .{ .loop = &loop };
    var ses_ctl_watcher: SesCtlWatcher = .{ .loop = &loop };
    var stdin_watcher: StdinWatcher = .{ .loop = &loop };

    // Frame timing.
    var last_render: i64 = std.time.milliTimestamp();
    var last_status_update: i64 = last_render;
    // Update status bar periodically.
    // This is also used to drive lightweight animations.
    const status_update_interval_base: i64 = core.constants.Timing.status_update_interval_base;
    const status_update_interval_anim: i64 = core.constants.Timing.status_update_interval_anim;
    const pane_sync_interval: i64 = core.constants.Timing.pane_sync_interval;
    const heartbeat_interval: i64 = core.constants.Timing.heartbeat_interval;

    var timer_ctx = LoopTimerContext{
        .state = state,
        .last_pane_sync = last_render,
        .last_heartbeat = last_render,
        .pane_sync_interval = pane_sync_interval,
        .heartbeat_interval = heartbeat_interval,
    };
    var timer_completion: xev.Completion = .{};
    loop_timer.run(&loop, &timer_completion, 100, LoopTimerContext, &timer_ctx, loopTimerCallback);

    // Reusable lists for dead pane tracking (avoid per-iteration allocations).
    var dead_splits: std.ArrayList(u16) = .empty;
    defer dead_splits.deinit(allocator);
    var dead_floating: std.ArrayList(usize) = .empty;
    defer dead_floating.deinit(allocator);

    // Main loop.
    while (state.running) {
        try loop.run(.no_wait);
        ensureSesVtWatcherArmed(state, &ses_vt_watcher, &ses_vt_buffer);
        ensureSesCtlWatcherArmed(state, &ses_ctl_watcher, &ses_ctl_buffer);
        ensureStdinWatcherArmed(state, &stdin_watcher, &stdin_buffer);

        // Clear skip flag from previous iteration.
        state.skip_dead_check = false;

        // Check for terminal resize.
        {
            const new_size = terminal.getTermSize();
            if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
                state.term_width = new_size.cols;
                state.term_height = new_size.rows;
                const status_h: u16 = if (state.config.tabs.status.enabled) 1 else 0;
                state.status_height = status_h;
                state.layout_width = new_size.cols;
                state.layout_height = new_size.rows - status_h;

                // Resize all tabs.
                for (state.tabs.items) |*tab| {
                    tab.layout.resize(state.layout_width, state.layout_height);
                }

                // Resize floats based on their stored percentages.
                state.resizeFloatingPanes();

                // Resize renderer and force full redraw.
                state.renderer.resize(new_size.cols, new_size.rows) catch {};
                state.renderer.invalidate();
                state.needs_render = true;
                state.force_full_render = true;
            }
        }

        // Proactively check for dead floats before polling.
        // Iterate in reverse to avoid O(n²) behavior from orderedRemove shifts.
        {
            if (state.floats.items.len > 0) {
                var fi: usize = state.floats.items.len;
                while (fi > 0) {
                    fi -= 1;
                    if (!state.floats.items[fi].isAlive()) {
                        // Check if this was the active float.
                        const was_active = if (state.active_floating) |af| af == fi else false;
                        const exit_code = state.floats.items[fi].getExitCode();

                        const pane = state.floats.orderedRemove(fi);

                        // Log float pane death
                        mux.debugLog("float pane died: uuid={s} exit_code={d} focused={}", .{ pane.uuid[0..8], exit_code, was_active });

                        // Show notification if float died with non-zero exit and wasn't focused
                        if (!was_active and exit_code != 0) {
                            const msg = std.fmt.allocPrint(
                                allocator,
                                "Background float exited with code {d}",
                                .{exit_code},
                            ) catch "Background float exited unexpectedly";
                            defer if (!std.mem.eql(u8, msg, "Background float exited unexpectedly")) allocator.free(msg);
                            state.notifications.showFor(msg, 3000);
                        }

                        float_completion.handleBlockingFloatCompletion(state, pane);

                        // Kill in ses (dead panes don't need to be orphaned).
                        if (state.ses_client.isConnected()) {
                            state.ses_client.killPane(pane.uuid) catch |e| {
                                core.logging.logError("mux", "killPane failed for float", e);
                            };
                        }

                        pane.deinit();
                        state.allocator.destroy(pane);
                        state.needs_render = true;
                        state.force_full_render = true;
                        state.renderer.invalidate();
                        state.syncStateToSes();

                        // Clear focus if this was the active float, sync focus to tiled pane.
                        if (was_active) {
                            state.active_floating = null;
                            // Force cursor restoration - float may have hidden cursor
                            state.cursor_needs_restore = true;
                            if (state.currentLayout().getFocusedPane()) |tiled| {
                                state.syncPaneFocus(tiled, null);
                            }
                        }
                        // When iterating in reverse, removals don't affect unprocessed indices.
                    }
                }
            }
            // Ensure active_floating is valid.
            if (state.active_floating) |af| {
                if (af >= state.floats.items.len) {
                    state.active_floating = if (state.floats.items.len > 0)
                        state.floats.items.len - 1
                    else
                        null;
                }
            }
        }

        // Build poll list for local pane PTYs.
        poll_fds.clearRetainingCapacity();

        var pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (pane.*.hasPollableFd()) {
                try poll_fds.append(allocator, .{
                    .fd = pane.*.getFd(),
                    .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
                    .revents = 0,
                });
            }
        }

        // Add local floats (pod floats get data via VT channel).
        for (state.floats.items) |pane| {
            if (pane.hasPollableFd()) {
                try poll_fds.append(allocator, .{
                    .fd = pane.getFd(),
                    .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR,
                    .revents = 0,
                });
            }
        }

        // Calculate poll timeout - wait for next frame, status update, or input.
        const now = std.time.milliTimestamp();
        const since_render = now - last_render;
        const since_status = now - last_status_update;
        const want_anim = blk: {
            const uuid = state.getCurrentFocusedUuid() orelse break :blk false;

            // If a float is focused, allow fast refresh (spinners in statusbar).
            if (state.active_floating != null) break :blk true;

            // suppress while alt-screen is active (for split-focused panes)
            const alt = if (state.currentLayout().getFocusedPane()) |pane| pane.vt.inAltScreen() else false;
            if (alt) break :blk false;

            // Prefer direct fg_process; fallback to cached process name.
            const fg = if (state.active_floating) |idx| blk3: {
                if (idx < state.floats.items.len) {
                    if (state.floats.items[idx].getFgProcess()) |p| break :blk3 p;
                }
                break :blk3 @as(?[]const u8, null);
            } else if (state.currentLayout().getFocusedPane()) |pane| pane.getFgProcess() else null;

            const proc_name = fg orelse blk4: {
                if (state.getPaneProc(uuid)) |pi| {
                    if (pi.name) |n| break :blk4 n;
                }
                break :blk4 @as(?[]const u8, null);
            };
            if (proc_name == null) break :blk false;

            const shells = [_][]const u8{ "bash", "zsh", "fish", "sh", "dash", "nu", "xonsh", "pwsh", "cmd", "elvish" };
            for (shells) |s| {
                if (std.mem.eql(u8, proc_name.?, s)) break :blk false;
            }

            break :blk true;
        };
        const status_update_interval: i64 = if (want_anim) status_update_interval_anim else status_update_interval_base;
        const until_status: i64 = @max(0, status_update_interval - since_status);
        const until_key_timer: i64 = blk: {
            if (state.nextKeyTimerDeadlineMs(now)) |deadline| {
                break :blk @max(0, deadline - now);
            }
            break :blk std.math.maxInt(i64);
        };
        const frame_timeout: i32 = if (!state.needs_render) 100 else if (since_render >= 16) 0 else @intCast(16 - since_render);
        const timeout: i32 = @intCast(@min(@as(i64, frame_timeout), @min(until_status, until_key_timer)));
        _ = posix.poll(poll_fds.items, timeout) catch continue;

        // Check if status bar needs periodic update.
        const now2 = std.time.milliTimestamp();

        // Auto-scroll while selecting when the mouse is near the top/bottom.
        // This allows selecting hidden content by holding the mouse at the edge.
        if (state.mouse_selection.active and state.mouse_selection.edge_scroll != .none) {
            const interval_ms: i64 = core.constants.Timing.key_timer_interval;
            if (now2 - state.mouse_selection_last_autoscroll_ms >= interval_ms) {
                state.mouse_selection_last_autoscroll_ms = now2;
                if (state.mouse_selection.pane_uuid) |uuid| {
                    if (state.findPaneByUuid(uuid)) |p| {
                        switch (state.mouse_selection.edge_scroll) {
                            .up => p.scrollUp(1),
                            .down => p.scrollDown(1),
                            .none => {},
                        }
                        // Recompute cursor in buffer coordinates for the current
                        // viewport after the scroll.
                        state.mouse_selection.update(p, state.mouse_selection.last_local.x, state.mouse_selection.last_local.y);
                        state.needs_render = true;
                    }
                }
            }
        }
        if (now2 - last_status_update >= status_update_interval) {
            state.needs_render = true;
            last_status_update = now2;
        }

        // Handle PTY output.
        // NOTE: we do this before handling stdin/actions that can mutate the
        // layout, so pollfd indices remain consistent with the pane iteration.
        var idx: usize = 0;
        dead_splits.clearRetainingCapacity();

        pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (!pane.*.hasPollableFd()) continue;
            if (idx < poll_fds.items.len) {
                if (poll_fds.items[idx].revents & posix.POLL.IN != 0) {
                    if (pane.*.poll(&buffer)) |had_data| {
                        if (had_data) {
                            // If the viewport is scrolled, new output still changes what should be visible:
                            // lines may be pushed into/out of scrollback, even if the top line stays anchored.
                            // Force the render snapshot to refresh so the contents don't "freeze".
                            pane.*.vt.invalidateRenderState();
                            state.needs_render = true;
                        }
                        if (pane.*.takeOscExpectResponse()) {
                            state.osc_reply_target_uuid = pane.*.uuid;
                        }
                        if (pane.*.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds.items[idx].revents & posix.POLL.HUP != 0) {
                    dead_splits.append(allocator, pane.*.id) catch {};
                } else if (poll_fds.items[idx].revents & posix.POLL.ERR != 0) {
                    // ERR without HUP — verify process actually exited.
                    if (!pane.*.isAlive()) {
                        dead_splits.append(allocator, pane.*.id) catch {};
                    }
                }
                idx += 1;
            }
        }

        // Handle floating pane output.
        dead_floating.clearRetainingCapacity();

        for (state.floats.items, 0..) |pane, fi| {
            if (!pane.hasPollableFd()) continue;
            if (idx < poll_fds.items.len) {
                if (poll_fds.items[idx].revents & posix.POLL.IN != 0) {
                    if (pane.poll(&buffer)) |had_data| {
                        if (had_data) {
                            pane.vt.invalidateRenderState();
                            state.needs_render = true;
                        }
                        if (pane.takeOscExpectResponse()) {
                            state.osc_reply_target_uuid = pane.uuid;
                        }
                        if (pane.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds.items[idx].revents & posix.POLL.HUP != 0) {
                    dead_floating.append(allocator, fi) catch {};
                } else if (poll_fds.items[idx].revents & posix.POLL.ERR != 0) {
                    // ERR without HUP — verify process actually exited.
                    if (!pane.isAlive()) {
                        dead_floating.append(allocator, fi) catch {};
                    }
                }
                idx += 1;
            }
        }

        // Check for dead pod panes (no per-pane fd to detect HUP).
        {
            var pod_pane_it = state.currentLayout().splitIterator();
            while (pod_pane_it.next()) |pane| {
                if (!pane.*.hasPollableFd() and !pane.*.isAlive()) {
                    dead_splits.append(allocator, pane.*.id) catch {};
                }
            }
        }

        // Remove dead floats (in reverse order to preserve indices).
        var df_idx: usize = dead_floating.items.len;
        while (df_idx > 0) {
            df_idx -= 1;
            const fi = dead_floating.items[df_idx];
            // Check if this was the active float before removing.
            const was_active = if (state.active_floating) |af| af == fi else false;

            const pane = state.floats.orderedRemove(fi);

            // Capture exit status (not yet set if detected via HUP/ERR).
            _ = pane.isAlive();

            float_completion.handleBlockingFloatCompletion(state, pane);

            // Kill in ses (dead panes don't need to be orphaned).
            if (state.ses_client.isConnected()) {
                state.ses_client.killPane(pane.uuid) catch |e| {
                    core.logging.logError("mux", "killPane failed for float", e);
                };
            }

            pane.deinit();
            state.allocator.destroy(pane);
            state.needs_render = true;
            state.force_full_render = true;
            state.renderer.invalidate();
            state.syncStateToSes();

            // Clear focus if this was the active float, sync focus to tiled pane.
            if (was_active) {
                state.active_floating = null;
                // Force cursor restoration - float may have hidden cursor
                state.cursor_needs_restore = true;
                if (state.currentLayout().getFocusedPane()) |tiled| {
                    state.syncPaneFocus(tiled, null);
                }
            }
        }
        // Ensure active_floating is still valid.
        if (state.active_floating) |af| {
            if (af >= state.floats.items.len) {
                state.active_floating = null;
            }
        }

        // Remove dead splits (skip if just respawned a shell).
        if (!state.skip_dead_check) {
            for (dead_splits.items) |dead_id| {
                // Find the dead pane to get exit status and determine if notification is needed
                const dead_pane = state.currentLayout().splits.get(dead_id);
                const was_focused = if (state.currentLayout().getFocusedPane()) |fp| fp.id == dead_id else false;
                const exit_code = if (dead_pane) |p| p.getExitCode() else 0;

                if (state.currentLayout().splitCount() > 1) {
                    // Multiple splits in tab - close the specific dead pane.
                    _ = state.currentLayout().closePane(dead_id);

                    // Log pane death
                    mux.debugLog("pane died: id={d} exit_code={d} focused={}", .{ dead_id, exit_code, was_focused });

                    // Show notification if pane died with non-zero exit or was unfocused (unexpected)
                    if (!was_focused and exit_code != 0) {
                        const msg = std.fmt.allocPrint(
                            allocator,
                            "Background pane exited with code {d}",
                            .{exit_code},
                        ) catch "Background pane exited unexpectedly";
                        defer if (!std.mem.eql(u8, msg, "Background pane exited unexpectedly")) allocator.free(msg);
                        state.notifications.showFor(msg, 3000);
                    }

                    if (state.currentLayout().getFocusedPane()) |new_pane| {
                        state.syncPaneFocus(new_pane, null);
                    }
                    state.syncStateToSes();
                    state.needs_render = true;
                } else if (state.tabs.items.len > 1) {
                    _ = state.closeCurrentTab();
                    state.needs_render = true;
                } else {
                    // If the shell asked permission to exit and we confirmed,
                    // don't ask again when it actually dies.
                    const now_ms = std.time.milliTimestamp();
                    if (state.exit_intent_deadline_ms > now_ms) {
                        state.exit_intent_deadline_ms = 0;
                        state.running = false;
                    } else if (state.config.confirm_on_exit and state.pending_action == null) {
                        state.pending_action = .exit;
                        state.exit_from_shell_death = true;
                        state.popups.showConfirm("Shell exited. Close mux?", .{}) catch {};
                        state.needs_render = true;
                    } else if (state.pending_action != .exit or !state.exit_from_shell_death) {
                        state.running = false;
                    }
                }
            }
        }

        // Handle deferred respawn (from shell death "No" response)
        if (state.needs_respawn) {
            state.needs_respawn = false;
            if (state.currentLayout().getFocusedPane()) |pane| {
                switch (pane.backend) {
                    .local => {
                        pane.respawn() catch {
                            state.notifications.show("Respawn failed");
                        };
                        state.skip_dead_check = true;
                        state.needs_render = true;
                    },
                    .pod => {
                        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
                        var cwd = state.getReliableCwd(pane);
                        if (cwd == null) {
                            cwd = std.posix.getcwd(&cwd_buf) catch null;
                        }
                        const old_aux = state.ses_client.getPaneAux(pane.uuid) catch SesClient.PaneAuxInfo{
                            .created_from = null,
                            .focused_from = null,
                        };
                        state.ses_client.killPane(pane.uuid) catch {};
                        if (state.ses_client.createPane(null, cwd, null, null, null, null)) |result| {
                            const vt_fd = state.ses_client.getVtFd();
                            var replaced = true;
                            if (vt_fd) |fd| {
                                pane.replaceWithPod(result.pane_id, fd, result.uuid) catch {
                                    replaced = false;
                                };
                            } else replaced = false;
                            if (replaced) {
                                const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
                                const cursor = pane.getCursorPos();
                                const cursor_style = pane.vt.getCursorStyle();
                                const cursor_visible = pane.vt.isCursorVisible();
                                const alt_screen = pane.vt.inAltScreen();
                                const layout_path = helpers.getLayoutPath(state, pane) catch null;
                                defer if (layout_path) |path| state.allocator.free(path);
                                state.ses_client.updatePaneAux(
                                    pane.uuid,
                                    pane.floating,
                                    pane.focused,
                                    pane_type,
                                    old_aux.created_from,
                                    old_aux.focused_from,
                                    .{ .x = cursor.x, .y = cursor.y },
                                    cursor_style,
                                    cursor_visible,
                                    alt_screen,
                                    .{ .cols = pane.width, .rows = pane.height },
                                    pane.getPwd(),
                                    null,
                                    null,
                                    layout_path,
                                ) catch {};
                                state.skip_dead_check = true;
                                state.needs_render = true;
                            } else {
                                state.notifications.show("Respawn failed");
                            }
                        } else |_| {
                            state.notifications.show("Respawn failed");
                        }
                    },
                }
            }
        }

        // Update MUX realm notifications.
        if (state.notifications.update()) {
            state.needs_render = true;
        }

        // Update overlays (expire info overlays, keycast entries).
        if (state.overlays.update()) {
            state.needs_render = true;
        }

        // Update MUX realm popups (check for timeout).
        const mux_popup_changed = state.popups.update();
        if (mux_popup_changed) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .mux and !state.popups.isBlocked()) {
                loop_ipc.sendPopResponse(state);
            }
        }

        // Update TAB realm notifications (current tab only).
        if (state.tabs.items[state.active_tab].notifications.update()) {
            state.needs_render = true;
        }

        // Update TAB realm popups (check for timeout).
        if (state.tabs.items[state.active_tab].popups.update()) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response.
            if (state.pending_pop_response and state.pending_pop_scope == .tab and !state.tabs.items[state.active_tab].popups.isBlocked()) {
                loop_ipc.sendPopResponse(state);
            }
        }

        // Update PANE realm notifications (splits).
        var notif_pane_it = state.currentLayout().splitIterator();
        while (notif_pane_it.next()) |pane| {
            if (pane.*.updateNotifications()) {
                state.needs_render = true;
            }
            // Update PANE realm popups (check for timeout).
            if (pane.*.updatePopups()) {
                state.needs_render = true;
                // Check if a popup timed out and we need to send response.
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane.* and !pane.*.popups.isBlocked()) {
                            loop_ipc.sendPopResponse(state);
                        }
                    }
                }
            }
        }

        // Update PANE realm notifications (floats).
        for (state.floats.items) |pane| {
            if (pane.updateNotifications()) {
                state.needs_render = true;
            }
            // Update PANE realm popups (check for timeout).
            if (pane.updatePopups()) {
                state.needs_render = true;
                // Check if a popup timed out and we need to send response.
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane and !pane.popups.isBlocked()) {
                            loop_ipc.sendPopResponse(state);
                        }
                    }
                }
            }
        }

        // Process keybinding timers (hold / double-tap delayed press).
        keybinds.processKeyTimers(state, now2);

        // Render with frame rate limiting (max 60fps).
        if (state.needs_render) {
            const render_now = std.time.milliTimestamp();
            if (render_now - last_render >= 16) { // ~60fps
                loop_render.renderTo(state, stdout) catch {};
                state.needs_render = false;
                state.force_full_render = false;
                last_render = render_now;
            }
        }
    }
}
