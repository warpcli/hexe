const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const input = @import("input.zig");
const loop_ipc = @import("loop_ipc.zig");
const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");

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

fn hasBind(_: *State, mods: u8, key: BindKey, on: BindWhen, query: *const PaneQuery, binds: []const core.Config.Bind) bool {
    for (binds) |b| {
        if (b.on != on) continue;
        if (b.mods != mods) continue;
        if (!keyEq(b.key, key)) continue;
        if (!matchesWhen(b.when, query)) continue;
        return true;
    }
    return false;
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

fn forwardKeyAsLegacy(state: *State, mods: u8, key: BindKey) void {
    var out: [8]u8 = undefined;
    var n: usize = 0;

    // Best-effort mapping used only when a key interaction was deferred.
    // In legacy terminals we generally won't defer, but keep this safe.
    switch (@as(BindKeyKind, key)) {
        .space => {
            out[n] = ' ';
            n += 1;
        },
        .char => {
            var ch: u8 = key.char;
            if ((mods & 4) != 0 and ch >= 'a' and ch <= 'z') ch = ch - 'a' + 'A';
            if ((mods & 2) != 0) {
                if (ch >= 'a' and ch <= 'z') ch = ch - 'a' + 1;
                if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 1;
            }
            if ((mods & 1) != 0) {
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
                _ = dispatchAction(state, t.action);
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

pub fn handleKeyEvent(state: *State, mods: u8, key: BindKey, when: BindWhen, allow_only_tabs: bool, defer_to_release: bool) bool {
    const cfg = &state.config;
    const focus_ctx = currentFocusContext(state);
    const query = buildPaneQuery(state);
    const now_ms = std.time.milliTimestamp();

    const mods_eff: u8 = blk: {
        if (!defer_to_release) break :blk mods;
        if (when == .press) break :blk mods;
        // Repeat/release events may come in without modifiers; reuse stored.
        if (mods != 0) break :blk mods;
        break :blk findStoredModsForKey(state, key, focus_ctx) orelse mods;
    };

    // Release cancels hold.
    if (when == .release) {
        // If a hold already fired, swallow the release and do not forward.
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

        // If a hold was pending but not fired yet, cancel and forward the key
        // into the pane (short tap behavior).
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

        // If we were deferring a tap decision, resolve it now.
        const tap_action: ?BindAction = blk: {
            var j: usize = 0;
            while (j < state.key_timers.items.len) {
                const t = state.key_timers.items[j];
                if (t.kind == .tap_pending and t.mods == mods_eff and keyEq(t.key, key)) {
                    _ = state.key_timers.orderedRemove(j);
                    break :blk t.action;
                }
                j += 1;
            }
            break :blk null;
        };

        if (had_hold_pending) {
            // Short hold => tap.
            if (tap_action) |a| {
                _ = dispatchAction(state, a);
            } else if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |b| {
                _ = dispatchAction(state, b.action);
            } else if (defer_to_release) {
                forwardKeyAsLegacy(state, mods_eff, key);
            }
            // Clean up repeat window if any.
            cancelTimer(state, .repeat_wait, mods_eff, key);
            return true;
        }

        // Repeat deferral resolution.
        var had_repeat_active = false;
        var had_repeat_wait = false;
        i = 0;
        while (i < state.key_timers.items.len) {
            const t = state.key_timers.items[i];
            if (t.mods == mods_eff and keyEq(t.key, key)) {
                if (t.kind == .repeat_active) {
                    _ = state.key_timers.orderedRemove(i);
                    had_repeat_active = true;
                    continue;
                }
                if (t.kind == .repeat_wait) {
                    _ = state.key_timers.orderedRemove(i);
                    had_repeat_wait = true;
                    continue;
                }
            }
            i += 1;
        }
        if (had_repeat_active) return true;
        if (had_repeat_wait) {
            // Repeat never activated => tap.
            if (tap_action) |a| {
                _ = dispatchAction(state, a);
            } else if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |b| {
                _ = dispatchAction(state, b.action);
            } else if (defer_to_release) {
                forwardKeyAsLegacy(state, mods_eff, key);
            }
            return true;
        }

        if (findBestBind(state, mods_eff, key, .release, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }
        // Always consume release events (they are mux-only).
        return true;
    }

    // Repeat: only fire repeat binds, don't participate in double tap.
    if (when == .repeat) {
        // Under the "primary key controls the chord" model, repeat mode is entered
        // by a second press within repeat_ms (not by the terminal's auto-repeat).
        // Therefore, ignore repeat events unless a repeat_active marker exists.

        var has_active = false;
        var i: usize = 0;
        while (i < state.key_timers.items.len) {
            if (state.key_timers.items[i].kind == .repeat_active and state.key_timers.items[i].mods == mods_eff and keyEq(state.key_timers.items[i].key, key)) {
                has_active = true;
                // Keep repeat mode alive while repeats arrive.
                state.key_timers.items[i].deadline_ms = now_ms + cfg.input.repeat_ms;
                break;
            }
            i += 1;
        }
        if (!has_active) return true;

        cancelTimer(state, .tap_pending, mods_eff, key);
        cancelTimer(state, .hold, mods_eff, key);
        cancelTimer(state, .hold_fired, mods_eff, key);

        if (findBestBind(state, mods_eff, key, .repeat, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }
        return true;
    }

    // Hold scheduling (press only)
    var hold_scheduled = false;
    if (when == .press and defer_to_release) {
        if (findBestBind(state, mods_eff, key, .hold, false, &query)) |hb| {
            const hold_ms = hb.hold_ms orelse cfg.input.hold_ms;
            cancelTimer(state, .hold, mods_eff, key);
            // Clear any previous fired marker for the same chord.
            cancelTimer(state, .hold_fired, mods_eff, key);
            scheduleTimer(state, .hold, now_ms + hold_ms, mods_eff, key, hb.action, focus_ctx);
            hold_scheduled = true;
        }
    }

    // Repeat/tap/hold arbitration for modified chords.
    // - If held past hold_ms: HOLD
    // - If repeated quickly (repeat event or a second press within repeat_ms): REPEAT
    // - Otherwise: TAP (fire press action on release)
    var chord_deferred = false;
    if (when == .press and defer_to_release and mods_eff != 0) {
        // If we are already in repeat_active (from rapid presses), treat this press as a repeat.
        {
            var j: usize = 0;
            while (j < state.key_timers.items.len) {
                const t = state.key_timers.items[j];
                if (t.kind == .repeat_active and t.mods == mods_eff and keyEq(t.key, key)) {
                    if (t.deadline_ms > now_ms) {
                        state.key_timers.items[j].deadline_ms = now_ms + cfg.input.repeat_ms;
                        return handleKeyEvent(state, mods_eff, key, .repeat, allow_only_tabs, defer_to_release);
                    }
                    // Expired repeat mode.
                    _ = state.key_timers.orderedRemove(j);
                    break;
                }
                j += 1;
            }
        }

        const press_bind = findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query);
        const have_repeat = hasBind(state, mods_eff, key, .repeat, &query, cfg.input.binds);
        const have_hold = hasBind(state, mods_eff, key, .hold, &query, cfg.input.binds);

        if (press_bind != null or have_repeat or have_hold) {
            // Second press within repeat_ms => treat as repeat.
            var k: usize = 0;
            while (k < state.key_timers.items.len) {
                if (state.key_timers.items[k].kind == .repeat_wait and state.key_timers.items[k].mods == mods_eff and keyEq(state.key_timers.items[k].key, key)) {
                    if (state.key_timers.items[k].deadline_ms > now_ms) {
                        // Activate repeat mode.
                        state.key_timers.items[k].kind = .repeat_active;
                        state.key_timers.items[k].deadline_ms = now_ms + cfg.input.repeat_ms;
                        cancelTimer(state, .tap_pending, mods_eff, key);
                        cancelTimer(state, .hold, mods_eff, key);
                        cancelTimer(state, .hold_fired, mods_eff, key);
                        return handleKeyEvent(state, mods_eff, key, .repeat, allow_only_tabs, defer_to_release);
                    }
                    // Window expired; start fresh.
                    _ = state.key_timers.orderedRemove(k);
                    break;
                }
                k += 1;
            }

            // Arm tap resolution if we have a press bind.
            if (press_bind) |pb| {
                cancelTimer(state, .tap_pending, mods_eff, key);
                scheduleTimer(state, .tap_pending, std.math.maxInt(i64), mods_eff, key, pb.action, focus_ctx);
                chord_deferred = true;
            }

            // Arm repeat window if a repeat bind exists.
            if (have_repeat) {
                cancelTimer(state, .repeat_wait, mods_eff, key);
                cancelTimer(state, .repeat_active, mods_eff, key);
                scheduleTimer(state, .repeat_wait, now_ms + cfg.input.repeat_ms, mods_eff, key, .mux_quit, focus_ctx);
                chord_deferred = true;
            }

            // Arm hold (done above). If we armed anything, consume press now.
            if (hold_scheduled or chord_deferred) return true;
        }
    }

    // Double tap handling (press only)
    if (when == .press and hasBind(state, mods_eff, key, .double_tap, &query, cfg.input.binds)) {
        const dt_bind = findBestBind(state, mods_eff, key, .double_tap, allow_only_tabs, &query);
        const dt_ms = if (dt_bind) |b| (b.double_tap_ms orelse cfg.input.double_tap_ms) else cfg.input.double_tap_ms;

        // Second tap?
        const had_wait = blk: {
            for (state.key_timers.items) |t| {
                if (t.kind == .double_tap_wait and t.mods == mods_eff and keyEq(t.key, key) and t.deadline_ms > now_ms and t.focus_ctx == focus_ctx) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (had_wait) {
            cancelTimer(state, .double_tap_wait, mods_eff, key);
            cancelTimer(state, .delayed_press, mods_eff, key);
            if (dt_bind) |db| {
                return dispatchAction(state, db.action);
            }
            return true;
        }
        scheduleTimer(state, .double_tap_wait, now_ms + dt_ms, mods_eff, key, .mux_quit, focus_ctx); // action ignored

        // If there's a press bind, delay it so it doesn't fire when user intends double.
        if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |pb| {
            const delay = pb.double_tap_ms orelse cfg.input.double_tap_ms;
            cancelTimer(state, .delayed_press, mods_eff, key);
            scheduleTimer(state, .delayed_press, now_ms + delay, mods_eff, key, pb.action, focus_ctx);
        }
        return true;
    }

    // Normal press
    if (when == .press) {
        // Hardcoded test: Ctrl+Alt+O toggles pane select mode (overlay test)
        // mods: alt=1, ctrl=2 => 3
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == 'o') {
            if (state.overlays.isPaneSelectActive()) {
                state.overlays.exitPaneSelectMode();
            } else {
                actions.enterPaneSelectMode(state, false);
            }
            return true;
        }

        // Hardcoded test: Ctrl+Alt+K toggles keycast mode (overlay test)
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == 'k') {
            state.overlays.toggleKeycast();
            state.needs_render = true;
            return true;
        }

        if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |b| {
            return dispatchAction(state, b.action);
        }

        // No press action matched, but we armed hold/repeat/tap deferral.
        if (hold_scheduled or chord_deferred) return true;
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
