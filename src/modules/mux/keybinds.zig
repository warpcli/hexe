const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const input = @import("input.zig");
const loop_ipc = @import("loop_ipc.zig");
const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");
const main = @import("main.zig");

pub const BindWhen = core.Config.BindWhen;
pub const BindKey = core.Config.BindKey;
pub const BindKeyKind = core.Config.BindKeyKind;
pub const BindAction = core.Config.BindAction;
const PaneQuery = core.PaneQuery;
const FocusContext = @import("state.zig").FocusContext;

pub fn forwardInputToFocusedPane(state: *State, bytes: []const u8) void {
    if (state.active_floating) |idx| {
        const fpane = state.floats.items[idx];
        const can_interact = if (fpane.parent_tab) |parent| parent == state.active_tab else true;
        if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
            if (fpane.popups.isBlocked()) {
                if (input.handlePopupInput(&fpane.popups, bytes)) {
                    loop_ipc.sendPopResponse(state);
                }
                state.needs_render = true;
                return;
            }
            if (fpane.isScrolled()) {
                fpane.scrollToBottom();
                state.needs_render = true;
            }
            fpane.write(bytes) catch {};
            return;
        }
    }

    if (state.currentLayout().getFocusedPane()) |pane| {
        if (pane.popups.isBlocked()) {
            if (input.handlePopupInput(&pane.popups, bytes)) {
                loop_ipc.sendPopResponse(state);
            }
            state.needs_render = true;
            return;
        }
        if (pane.isScrolled()) {
            pane.scrollToBottom();
            state.needs_render = true;
        }
        pane.write(bytes) catch {};
    }
}

/// Forward a key (with modifiers) to the focused pane as legacy escape sequence.
fn forwardKeyToPane(state: *State, mods: u8, key: BindKey) void {
    var out: [8]u8 = undefined;
    var n: usize = 0;

    switch (@as(BindKeyKind, key)) {
        .space => {
            if ((mods & 1) != 0) { // Alt
                out[n] = 0x1b;
                n += 1;
            }
            out[n] = ' ';
            n += 1;
        },
        .char => {
            var ch: u8 = key.char;
            if ((mods & 4) != 0 and ch >= 'a' and ch <= 'z') ch = ch - 'a' + 'A'; // Shift
            if ((mods & 2) != 0) { // Ctrl
                if (ch >= 'a' and ch <= 'z') ch = ch - 'a' + 1;
                if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 1;
            }
            if ((mods & 1) != 0) { // Alt
                out[n] = 0x1b;
                n += 1;
            }
            out[n] = ch;
            n += 1;
        },
        else => return,
    }

    if (n > 0) forwardInputToFocusedPane(state, out[0..n]);
}

/// Legacy focus context for backward compatibility with timer storage.
fn currentFocusContext(state: *State) FocusContext {
    return if (state.active_floating != null) .float else .split;
}

/// Build a PaneQuery from the current mux state for condition evaluation.
fn buildPaneQuery(state: *State) PaneQuery {
    const is_float = state.active_floating != null;
    const pane: ?*Pane = if (state.active_floating) |idx| blk: {
        if (idx < state.floats.items.len) break :blk state.floats.items[idx];
        break :blk @as(?*Pane, null);
    } else state.currentLayout().getFocusedPane();

    // Get foreground process name.
    const fg_proc: ?[]const u8 = blk: {
        if (pane) |p| {
            if (p.getFgProcess()) |proc_name| break :blk proc_name;
        }
        if (state.getCurrentFocusedUuid()) |uuid| {
            if (state.getPaneProc(uuid)) |pi| {
                if (pi.name) |n| break :blk n;
            }
        }
        break :blk null;
    };

    // Get float attributes if this is a float.
    var float_key: u8 = 0;
    var float_sticky = false;
    var float_exclusive = false;
    var float_per_cwd = false;
    var float_global = false;
    var float_isolated = false;
    var float_destroyable = false;

    if (pane) |p| {
        if (is_float) {
            float_key = p.float_key;
            float_sticky = p.sticky;
            // Look up float def for other attributes.
            if (float_key != 0) {
                if (state.getLayoutFloatByKey(float_key)) |fd| {
                    float_exclusive = fd.attributes.exclusive;
                    float_per_cwd = fd.attributes.per_cwd;
                    float_global = fd.attributes.global or fd.attributes.per_cwd;
                    float_isolated = fd.attributes.isolated;
                    float_destroyable = fd.attributes.destroy;
                }
            }
        }
    }

    return .{
        .is_float = is_float,
        .is_split = !is_float,
        .float_key = float_key,
        .float_sticky = float_sticky,
        .float_exclusive = float_exclusive,
        .float_per_cwd = float_per_cwd,
        .float_global = float_global,
        .float_isolated = float_isolated,
        .float_destroyable = float_destroyable,
        .tab_count = @intCast(state.tabs.items.len),
        .active_tab = @intCast(state.active_tab),
        .fg_process = fg_proc,
        .now_ms = @intCast(std.time.milliTimestamp()),
    };
}

/// Evaluate a bind's when condition against the current state.
fn matchesWhen(when: ?core.config.WhenDef, query: *const PaneQuery) bool {
    if (when) |w| {
        return core.query.evalWhen(query, w);
    }
    return true; // No condition = always matches.
}

fn keyEq(a: BindKey, b: BindKey) bool {
    if (@as(BindKeyKind, a) != @as(BindKeyKind, b)) return false;
    if (@as(BindKeyKind, a) == .char) return a.char == b.char;
    return true;
}

fn findBestBind(state: *State, mods: u8, key: BindKey, on: BindWhen, allow_only_tabs: bool, query: *const PaneQuery) ?core.Config.Bind {
    const cfg = &state.config;

    var best: ?core.Config.Bind = null;
    var best_score: u8 = 0;

    for (cfg.input.binds) |b| {
        if (b.on != on) continue;
        if (b.mods != mods) continue;
        if (!keyEq(b.key, key)) continue;
        if (!matchesWhen(b.when, query)) continue;

        if (allow_only_tabs) {
            if (b.action != .tab_next and b.action != .tab_prev) continue;
        }

        var score: u8 = 0;
        if (b.when != null) score += 2; // Conditional binds are more specific.
        if (b.hold_ms != null) score += 1;
        if (b.double_tap_ms != null) score += 1;

        if (best == null or score > best_score or score == best_score) {
            best = b;
            best_score = score;
        }
    }

    return best;
}

fn cancelTimer(state: *State, kind: State.PendingKeyTimerKind, mods: u8, key: BindKey) void {
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == kind and t.mods == mods and keyEq(t.key, key)) {
            _ = state.key_timers.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

fn findStoredModsForKey(state: *State, key: BindKey, focus_ctx: FocusContext) ?u8 {
    // When a terminal reports repeat/release with missing modifier bits, we still
    // need to resolve the chord using the modifiers from the original press.
    for (state.key_timers.items) |t| {
        if (!keyEq(t.key, key)) continue;
        if (t.focus_ctx != focus_ctx) continue;
        switch (t.kind) {
            .tap_pending, .hold, .hold_fired, .repeat_wait, .repeat_active, .double_tap_wait, .delayed_press => return t.mods,
        }
    }
    return null;
}

fn scheduleTimer(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext) void {
    state.key_timers.append(state.allocator, .{
        .kind = kind,
        .deadline_ms = deadline_ms,
        .mods = mods,
        .key = key,
        .action = action,
        .focus_ctx = focus_ctx,
    }) catch {};
}

pub fn processKeyTimers(state: *State, now_ms: i64) void {
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .hold_fired or t.kind == .repeat_wait or t.kind == .repeat_active) {
            i += 1;
            continue;
        }
        if (t.deadline_ms > now_ms) {
            i += 1;
            continue;
        }

        // Hold timers need to survive until release so we can decide whether to
        // forward the key to the pane.
        if (t.kind == .hold) {
            // Enforce context at fire time.
            if (t.focus_ctx == currentFocusContext(state)) {
                // Test: Ctrl+Alt+; hold = HOLD notification
                if (t.mods == 3 and @as(BindKeyKind, t.key) == .char and t.key.char == ';') {
                    state.notifications.show("HOLD");
                    state.needs_render = true;
                } else {
                    _ = dispatchAction(state, t.action);
                }
            }
            state.key_timers.items[i].kind = .hold_fired;
            state.key_timers.items[i].deadline_ms = std.math.maxInt(i64);
            i += 1;
            continue;
        }

        _ = state.key_timers.orderedRemove(i);

        // Enforce context at fire time.
        if (t.focus_ctx != currentFocusContext(state)) {
            continue;
        }

        switch (t.kind) {
            .double_tap_wait => {},
            .tap_pending => {},
            .delayed_press => {
                _ = dispatchAction(state, t.action);
            },
            .hold_fired => {},
            .repeat_wait => {},
            .repeat_active => {},
            .hold => unreachable,
        }
    }
}

pub fn handleKeyEvent(state: *State, mods: u8, key: BindKey, when: BindWhen, allow_only_tabs: bool, kitty_mode: bool) bool {
    const cfg = &state.config;
    const query = buildPaneQuery(state);

    // =======================================================
    // LEGACY MODE: Just fire press bindings immediately.
    // No hold, no repeat, no tap deferral - simple and predictable.
    // =======================================================
    if (!kitty_mode) {
        if (when != .press) return true; // Ignore non-press in legacy

        // Hardcoded test: Ctrl+Alt+O toggles pane select mode
        if (mods == 3 and @as(BindKeyKind, key) == .char and key.char == 'o') {
            if (state.overlays.isPaneSelectActive()) {
                state.overlays.exitPaneSelectMode();
            } else {
                actions.enterPaneSelectMode(state, false);
            }
            return true;
        }

        // Hardcoded test: Ctrl+Alt+K toggles keycast mode
        if (mods == 3 and @as(BindKeyKind, key) == .char and key.char == 'k') {
            state.overlays.toggleKeycast();
            state.needs_render = true;
            return true;
        }

        if (findBestBind(state, mods, key, .press, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }
        return false;
    }

    // =======================================================
    // KITTY MODE: Full press/hold/repeat/release support.
    // Terminal sends explicit event types via CSI-u protocol.
    // =======================================================
    const focus_ctx = currentFocusContext(state);
    const now_ms = std.time.milliTimestamp();

    // Modifier latching: repeat/release may arrive with mods=0 if user
    // released the modifier before the primary key. Use stored mods.
    const mods_eff: u8 = blk: {
        if (when == .press) break :blk mods;
        if (mods != 0) break :blk mods;
        break :blk findStoredModsForKey(state, key, focus_ctx) orelse mods;
    };

    // --- RELEASE ---
    if (when == .release) {
        // Test: Ctrl+Alt+; release after hold = HOLD notification
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == ';') {
            // Check if hold_fired exists - means hold action already fired
            var had_hold_fired = false;
            var i: usize = 0;
            while (i < state.key_timers.items.len) {
                const t = state.key_timers.items[i];
                if (t.kind == .hold_fired and t.mods == mods_eff and keyEq(t.key, key)) {
                    _ = state.key_timers.orderedRemove(i);
                    had_hold_fired = true;
                    continue;
                }
                i += 1;
            }
            // Check if hold was pending (tap)
            var had_hold_pending = false;
            i = 0;
            while (i < state.key_timers.items.len) {
                const t = state.key_timers.items[i];
                if (t.kind == .hold and t.mods == mods_eff and keyEq(t.key, key)) {
                    _ = state.key_timers.orderedRemove(i);
                    had_hold_pending = true;
                    continue;
                }
                i += 1;
            }
            cancelTimer(state, .repeat_active, mods_eff, key);
            if (had_hold_pending) {
                state.notifications.show("TAP");
                state.needs_render = true;
            }
            return true;
        }

        // If hold already fired, just clean up
        var had_hold_fired = false;
        var i: usize = 0;
        while (i < state.key_timers.items.len) {
            const t = state.key_timers.items[i];
            if (t.kind == .hold_fired and t.mods == mods_eff and keyEq(t.key, key)) {
                _ = state.key_timers.orderedRemove(i);
                had_hold_fired = true;
                continue;
            }
            i += 1;
        }
        if (had_hold_fired) return true;

        // If hold was pending (not fired), this is a tap - fire press action
        var had_hold_pending = false;
        i = 0;
        while (i < state.key_timers.items.len) {
            const t = state.key_timers.items[i];
            if (t.kind == .hold and t.mods == mods_eff and keyEq(t.key, key)) {
                _ = state.key_timers.orderedRemove(i);
                had_hold_pending = true;
                continue;
            }
            i += 1;
        }

        // Clean up repeat_active if any
        cancelTimer(state, .repeat_active, mods_eff, key);

        // Tap: hold was pending but didn't fire
        if (had_hold_pending) {
            main.debugLog("release tap: mods_eff={d} key={any}", .{ mods_eff, key });
            if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |b| {
                main.debugLog("release tap: found bind, action={any}", .{b.action});
                _ = dispatchAction(state, b.action);
            } else {
                // No press bind - forward key to shell on release
                main.debugLog("release tap: no bind, forwarding to shell", .{});
                forwardKeyToPane(state, mods_eff, key);
            }
            return true;
        }

        // Fire release bind if exists
        if (findBestBind(state, mods_eff, key, .release, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }
        return true;
    }

    // --- REPEAT ---
    if (when == .repeat) {
        // Test: Ctrl+Alt+; repeat = REPEAT notification
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == ';') {
            cancelTimer(state, .hold, mods_eff, key);
            cancelTimer(state, .hold_fired, mods_eff, key);
            state.notifications.show("REPEAT");
            state.needs_render = true;
            return true;
        }

        // Terminal auto-repeat: cancel hold timer (repeating != holding)
        cancelTimer(state, .hold, mods_eff, key);
        cancelTimer(state, .hold_fired, mods_eff, key);

        // Keep repeat_active alive (or create if first repeat event)
        var found = false;
        for (state.key_timers.items) |*t| {
            if (t.kind == .repeat_active and t.mods == mods_eff and keyEq(t.key, key)) {
                t.deadline_ms = now_ms + cfg.input.repeat_ms;
                found = true;
                break;
            }
        }
        if (!found) {
            scheduleTimer(state, .repeat_active, now_ms + cfg.input.repeat_ms, mods_eff, key, .mux_quit, focus_ctx);
        }

        // Fire repeat bind
        if (findBestBind(state, mods_eff, key, .repeat, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }
        return true;
    }

    // --- PRESS ---
    if (when == .press) {
        // Debug: log all Ctrl+Alt presses
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char) {
            main.debugLog("press: Ctrl+Alt+{c} (0x{x})", .{ key.char, key.char });
        }

        // Test: Ctrl+Alt+; press = arm hold timer for HOLD test
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == ';') {
            main.debugLog("test key matched, arming hold timer", .{});
            cancelTimer(state, .hold, mods_eff, key);
            cancelTimer(state, .hold_fired, mods_eff, key);
            // Arm hold timer - when it fires, show HOLD notification
            scheduleTimer(state, .hold, now_ms + cfg.input.hold_ms, mods_eff, key, .mux_quit, focus_ctx);
            return true;
        }

        // Hardcoded test: Ctrl+Alt+O toggles pane select mode
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == 'o') {
            if (state.overlays.isPaneSelectActive()) {
                state.overlays.exitPaneSelectMode();
            } else {
                actions.enterPaneSelectMode(state, false);
            }
            return true;
        }

        // Hardcoded test: Ctrl+Alt+K toggles keycast mode
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == 'k') {
            state.overlays.toggleKeycast();
            state.needs_render = true;
            return true;
        }

        // For modified keys, ALWAYS defer press until release (tap vs hold behavior).
        // This prevents keys from leaking to shell while user is still pressing modifiers.
        if (mods_eff != 0) {
            main.debugLog("press defer: mods_eff={d} key={any}", .{ mods_eff, key });
            if (findBestBind(state, mods_eff, key, .hold, false, &query)) |hb| {
                const hold_ms = hb.hold_ms orelse cfg.input.hold_ms;
                cancelTimer(state, .hold, mods_eff, key);
                cancelTimer(state, .hold_fired, mods_eff, key);
                scheduleTimer(state, .hold, now_ms + hold_ms, mods_eff, key, hb.action, focus_ctx);
            } else {
                // No hold bind - arm dummy hold timer to defer until release
                cancelTimer(state, .hold, mods_eff, key);
                scheduleTimer(state, .hold, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx);
            }
            return true; // Wait for release
        }

        // Unmodified keys - fire press immediately
        if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }
    }

    return false;
}

fn dispatchAction(state: *State, action: BindAction) bool {
    const cfg = &state.config;

    switch (action) {
        .mux_quit => {
            if (cfg.confirm_on_exit) {
                state.pending_action = .exit;
                state.popups.showConfirm("Exit mux?", .{}) catch {};
                state.needs_render = true;
            } else {
                state.running = false;
            }
            return true;
        },
        .pane_disown => {
            const current_pane: ?*Pane = if (state.active_floating) |idx|
                state.floats.items[idx]
            else
                state.currentLayout().getFocusedPane();

            if (current_pane) |p| {
                if (p.sticky) {
                    state.notifications.show("Cannot disown sticky float");
                    state.needs_render = true;
                    return true;
                }
            }

            if (cfg.confirm_on_disown) {
                state.pending_action = .disown;
                state.popups.showConfirm("Disown pane?", .{}) catch {};
                state.needs_render = true;
            } else {
                actions.performDisown(state);
            }
            return true;
        },
        .pane_adopt => {
            actions.startAdoptFlow(state);
            return true;
        },
        .pane_select_mode => {
            actions.enterPaneSelectMode(state, false);
            return true;
        },
        .keycast_toggle => {
            state.overlays.toggleKeycast();
            state.needs_render = true;
            return true;
        },
        .split_h => {
            const parent_uuid = state.getCurrentFocusedUuid();
            const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
            if (state.currentLayout().splitFocused(.horizontal, cwd) catch null) |new_pane| {
                state.syncPaneAux(new_pane, parent_uuid);
            }
            state.needs_render = true;
            state.syncStateToSes();
            return true;
        },
        .split_v => {
            const parent_uuid = state.getCurrentFocusedUuid();
            const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
            if (state.currentLayout().splitFocused(.vertical, cwd) catch null) |new_pane| {
                state.syncPaneAux(new_pane, parent_uuid);
            }
            state.needs_render = true;
            state.syncStateToSes();
            return true;
        },
        .split_resize => |dir_kind| {
            // Only applies to split panes (floats should ignore).
            if (state.active_floating != null) return true;
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir == null) return true;
            if (state.currentLayout().resizeFocused(dir.?, 1)) {
                state.needs_render = true;
                state.renderer.invalidate();
                state.force_full_render = true;
            }
            return true;
        },
        .tab_new => {
            state.active_floating = null;
            state.createTab() catch |e| {
                core.logging.logError("mux", "createTab failed", e);
            };
            state.needs_render = true;
            return true;
        },
        .tab_next => {
            const old_uuid = state.getCurrentFocusedUuid();
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    const fp = state.floats.items[idx];
                    state.syncPaneUnfocus(fp);
                    state.active_floating = null;
                }
            } else if (state.currentLayout().getFocusedPane()) |old_pane| {
                state.syncPaneUnfocus(old_pane);
            }
            state.nextTab();

            if (state.tab_last_focus_kind.items.len > state.active_tab and state.tab_last_focus_kind.items[state.active_tab] == .float) {
                if (state.tab_last_floating_uuid.items.len > state.active_tab) {
                    if (state.tab_last_floating_uuid.items[state.active_tab]) |uuid| {
                        for (state.floats.items, 0..) |pane, fi| {
                            if (!std.mem.eql(u8, &pane.uuid, &uuid)) continue;
                            if (!pane.isVisibleOnTab(state.active_tab)) continue;
                            if (pane.parent_tab) |parent| {
                                if (parent != state.active_tab) continue;
                            }
                            state.active_floating = fi;
                            state.syncPaneFocus(pane, old_uuid);
                            state.needs_render = true;
                            return true;
                        }
                    }
                }
            }

            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }
            state.needs_render = true;
            return true;
        },
        .tab_prev => {
            const old_uuid = state.getCurrentFocusedUuid();
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    const fp = state.floats.items[idx];
                    state.syncPaneUnfocus(fp);
                    state.active_floating = null;
                }
            } else if (state.currentLayout().getFocusedPane()) |old_pane| {
                state.syncPaneUnfocus(old_pane);
            }
            state.prevTab();

            if (state.tab_last_focus_kind.items.len > state.active_tab and state.tab_last_focus_kind.items[state.active_tab] == .float) {
                if (state.tab_last_floating_uuid.items.len > state.active_tab) {
                    if (state.tab_last_floating_uuid.items[state.active_tab]) |uuid| {
                        for (state.floats.items, 0..) |pane, fi| {
                            if (!std.mem.eql(u8, &pane.uuid, &uuid)) continue;
                            if (!pane.isVisibleOnTab(state.active_tab)) continue;
                            if (pane.parent_tab) |parent| {
                                if (parent != state.active_tab) continue;
                            }
                            state.active_floating = fi;
                            state.syncPaneFocus(pane, old_uuid);
                            state.needs_render = true;
                            return true;
                        }
                    }
                }
            }

            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }
            state.needs_render = true;
            return true;
        },
        .pane_close => {
            // Close float or split pane, but never the tab.
            if (state.active_floating != null) {
                // Close the focused float.
                if (cfg.confirm_on_close) {
                    state.pending_action = .close;
                    state.popups.showConfirm("Close float?", .{}) catch {};
                    state.needs_render = true;
                } else {
                    actions.performClose(state);
                }
            } else {
                // Close split pane if there are multiple splits.
                const layout = state.currentLayout();
                if (layout.splitCount() > 1) {
                    if (cfg.confirm_on_close) {
                        state.pending_action = .pane_close;
                        state.popups.showConfirm("Close pane?", .{}) catch {};
                        state.needs_render = true;
                    } else {
                        _ = layout.closePane(layout.focused_split_id);
                        if (layout.getFocusedPane()) |new_pane| {
                            state.syncPaneFocus(new_pane, null);
                        }
                        state.syncStateToSes();
                        state.needs_render = true;
                    }
                }
                // If only one pane, do nothing (don't close the tab).
            }
            return true;
        },
        .tab_close => {
            if (cfg.confirm_on_close) {
                state.pending_action = .close;
                const msg = if (state.active_floating != null) "Close float?" else "Close tab?";
                state.popups.showConfirm(msg, .{}) catch {};
                state.needs_render = true;
            } else {
                actions.performClose(state);
            }
            return true;
        },
        .mux_detach => {
            if (cfg.confirm_on_detach) {
                state.pending_action = .detach;
                state.popups.showConfirm("Detach session?", .{}) catch {};
                state.needs_render = true;
                return true;
            }
            actions.performDetach(state);
            return true;
        },
        .float_toggle => |fk| {
            if (state.getLayoutFloatByKey(fk)) |float_def| {
                actions.toggleNamedFloat(state, float_def);
                state.needs_render = true;
                return true;
            }
            return false;
        },
        .float_nudge => |dir_kind| {
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir == null) return false;
            const fi = state.active_floating orelse return false;
            if (fi >= state.floats.items.len) return false;
            const pane = state.floats.items[fi];
            if (pane.parent_tab) |parent| {
                if (parent != state.active_tab) return false;
            }

            nudgeFloat(state, pane, dir.?, 1);
            state.needs_render = true;
            return true;
        },
        .focus_move => |dir_kind| {
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir) |d| return focus_move.perform(state, d);
            return true;
        },
    }
}

fn nudgeFloat(state: *State, pane: *Pane, dir: layout_mod.Layout.Direction, step_cells: u16) void {
    const avail_h: u16 = state.term_height - state.status_height;

    const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;

    const outer_w: u16 = usable_w * pane.float_width_pct / 100;
    const outer_h: u16 = usable_h * pane.float_height_pct / 100;

    const max_x: u16 = usable_w -| outer_w;
    const max_y: u16 = usable_h -| outer_h;

    var outer_x: i32 = @intCast(pane.border_x);
    var outer_y: i32 = @intCast(pane.border_y);
    const dx: i32 = switch (dir) {
        .left => -@as(i32, @intCast(step_cells)),
        .right => @as(i32, @intCast(step_cells)),
        else => 0,
    };
    const dy: i32 = switch (dir) {
        .up => -@as(i32, @intCast(step_cells)),
        .down => @as(i32, @intCast(step_cells)),
        else => 0,
    };

    outer_x += dx;
    outer_y += dy;

    if (outer_x < 0) outer_x = 0;
    if (outer_y < 0) outer_y = 0;
    if (outer_x > @as(i32, @intCast(max_x))) outer_x = @as(i32, @intCast(max_x));
    if (outer_y > @as(i32, @intCast(max_y))) outer_y = @as(i32, @intCast(max_y));

    // Convert back to percentage (stable across resizes).
    if (max_x > 0) {
        const xp: u32 = (@as(u32, @intCast(outer_x)) * 100) / @as(u32, max_x);
        pane.float_pos_x_pct = @intCast(@min(100, xp));
    }
    if (max_y > 0) {
        const yp: u32 = (@as(u32, @intCast(outer_y)) * 100) / @as(u32, max_y);
        pane.float_pos_y_pct = @intCast(@min(100, yp));
    }

    state.resizeFloatingPanes();
}
