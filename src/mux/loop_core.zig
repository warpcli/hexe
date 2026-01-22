const std = @import("std");
const posix = std.posix;

const terminal = @import("terminal.zig");

const State = @import("state.zig").State;

const loop_input = @import("loop_input.zig");
const loop_ipc = @import("loop_ipc.zig");
const loop_render = @import("loop_render.zig");
const float_completion = @import("float_completion.zig");
const keybinds = @import("keybinds.zig");

pub fn runMainLoop(state: *State) !void {
    const allocator = state.allocator;

    // Enter raw mode.
    const orig_termios = try terminal.enableRawMode(posix.STDIN_FILENO);
    defer terminal.disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen and reset it.
    const stdout = std.fs.File.stdout();
    // NOTE: Do not enable kitty keyboard protocol by default.
    // Some terminals will start emitting CSI-u sequences when they see unknown
    // keyboard mode requests, and any parsing mismatch can leak garbage into the
    // underlying shell (e.g. "3u" fragments).
    try stdout.writeAll("\x1b[?1049h\x1b[2J\x1b[3J\x1b[H\x1b[0m\x1b(B\x1b)0\x0f\x1b[?25l\x1b[?1000h\x1b[?1006h");
    defer stdout.writeAll("\x1b[?1006l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    // Build poll fds.
    var poll_fds: [17]posix.pollfd = undefined; // stdin + up to 16 panes
    var buffer: [1024 * 1024]u8 = undefined; // Larger buffer for efficiency

    // Frame timing.
    var last_render: i64 = std.time.milliTimestamp();
    var last_status_update: i64 = last_render;
    var last_pane_sync: i64 = last_render;
    const status_update_interval: i64 = 250; // Update status bar every 250ms
    const pane_sync_interval: i64 = 1000; // Sync pane info (CWD, process) every 1s

    // Main loop.
    while (state.running) {
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
        {
            var fi: usize = 0;
            while (fi < state.floats.items.len) {
                if (!state.floats.items[fi].isAlive()) {
                    // Check if this was the active float.
                    const was_active = if (state.active_floating) |af| af == fi else false;

                    const pane = state.floats.orderedRemove(fi);
                    float_completion.handleBlockingFloatCompletion(state, pane);

                    // Kill in ses (dead panes don't need to be orphaned).
                    if (state.ses_client.isConnected()) {
                        state.ses_client.killPane(pane.uuid) catch {};
                    }

                    pane.deinit();
                    state.allocator.destroy(pane);
                    state.needs_render = true;
                    state.syncStateToSes();

                    // Clear focus if this was the active float, sync focus to tiled pane.
                    if (was_active) {
                        state.active_floating = null;
                        if (state.currentLayout().getFocusedPane()) |tiled| {
                            state.syncPaneFocus(tiled, null);
                        }
                    }
                    // Don't increment fi, next item shifted into this position.
                } else {
                    fi += 1;
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

        // Build poll list: stdin + all pane PTYs.
        var fd_count: usize = 1;
        poll_fds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };

        var pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.*.getFd(), .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add floats.
        for (state.floats.items) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.getFd(), .events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add ses connection fd if connected.
        var ses_fd_idx: ?usize = null;
        if (state.ses_client.conn) |conn| {
            if (fd_count < poll_fds.len) {
                ses_fd_idx = fd_count;
                poll_fds[fd_count] = .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add IPC server fd for incoming connections.
        var ipc_fd_idx: ?usize = null;
        if (state.ipc_server) |srv| {
            if (fd_count < poll_fds.len) {
                ipc_fd_idx = fd_count;
                poll_fds[fd_count] = .{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Calculate poll timeout - wait for next frame, status update, or input.
        const now = std.time.milliTimestamp();
        const since_render = now - last_render;
        const since_status = now - last_status_update;
        const until_status: i64 = @max(0, status_update_interval - since_status);
        const until_key_timer: i64 = blk: {
            if (state.nextKeyTimerDeadlineMs(now)) |deadline| {
                break :blk @max(0, deadline - now);
            }
            break :blk std.math.maxInt(i64);
        };
        const frame_timeout: i32 = if (!state.needs_render) 100 else if (since_render >= 16) 0 else @intCast(16 - since_render);
        const timeout: i32 = @intCast(@min(@as(i64, frame_timeout), @min(until_status, until_key_timer)));
        _ = posix.poll(poll_fds[0..fd_count], timeout) catch continue;

        // Check if status bar needs periodic update.
        const now2 = std.time.milliTimestamp();
        if (now2 - last_status_update >= status_update_interval) {
            state.needs_render = true;
            last_status_update = now2;
        }

        // Periodic sync of pane info (CWD, fg_process) to ses.
        if (now2 - last_pane_sync >= pane_sync_interval) {
            last_pane_sync = now2;
            state.syncFocusedPaneInfo();
        }

        // Handle PTY output.
        // NOTE: we do this before handling stdin/actions that can mutate the
        // layout, so pollfd indices remain consistent with the pane iteration.
        var idx: usize = 1;
        var dead_splits: std.ArrayList(u16) = .empty;
        defer dead_splits.deinit(allocator);

        pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.*.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.*.takeOscExpectResponse()) {
                            state.osc_reply_target_uuid = pane.*.uuid;
                        }
                        if (pane.*.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_splits.append(allocator, pane.*.id) catch {};
                }
                idx += 1;
            }
        }

        // Handle floating pane output.
        var dead_floating: std.ArrayList(usize) = .empty;
        defer dead_floating.deinit(allocator);

        for (state.floats.items, 0..) |pane, fi| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.takeOscExpectResponse()) {
                            state.osc_reply_target_uuid = pane.uuid;
                        }
                        if (pane.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_floating.append(allocator, fi) catch {};
                }
                idx += 1;
            }
        }

        // Handle ses messages.
        if (ses_fd_idx) |sidx| {
            if (poll_fds[sidx].revents & posix.POLL.IN != 0) {
                loop_ipc.handleSesMessage(state, &buffer);
            }
        }

        // Handle IPC connections (for --notify / ad-hoc floats).
        if (ipc_fd_idx) |iidx| {
            if (poll_fds[iidx].revents & posix.POLL.IN != 0) {
                loop_ipc.handleIpcConnection(state, &buffer);
            }
        }

        // Handle stdin.
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buffer) catch break;
            if (n == 0) break;
            loop_input.handleInput(state, buffer[0..n]);
        }

        // Remove dead floats (in reverse order to preserve indices).
        var df_idx: usize = dead_floating.items.len;
        while (df_idx > 0) {
            df_idx -= 1;
            const fi = dead_floating.items[df_idx];
            // Check if this was the active float before removing.
            const was_active = if (state.active_floating) |af| af == fi else false;

            const pane = state.floats.orderedRemove(fi);
            float_completion.handleBlockingFloatCompletion(state, pane);
            pane.deinit();
            state.allocator.destroy(pane);
            state.needs_render = true;

            // Clear focus if this was the active float.
            if (was_active) {
                state.active_floating = null;
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
                if (state.currentLayout().splitCount() > 1) {
                    // Multiple splits in tab - close the specific dead pane.
                    _ = state.currentLayout().closePane(dead_id);
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

        // Update MUX realm notifications.
        if (state.notifications.update()) {
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
