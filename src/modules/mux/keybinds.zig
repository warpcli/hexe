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

/// Forward a key (with modifiers) to the focused pane as escape sequence.
pub fn forwardKeyToPane(state: *State, mods: u8, key: BindKey) void {
    var out: [16]u8 = undefined;
    var n: usize = 0;

    switch (@as(BindKeyKind, key)) {
        .space => {
            if ((mods & 2) != 0) { // Ctrl+Space = NUL
                out[n] = 0x00;
                n += 1;
            } else {
                if ((mods & 1) != 0) { // Alt
                    out[n] = 0x1b;
                    n += 1;
                }
                out[n] = ' ';
                n += 1;
            }
        },
        .char => {
            var ch: u8 = key.char;
            // Shift+Tab = backtab (CSI Z)
            if ((mods & 4) != 0 and ch == 0x09) {
                out[n] = 0x1b;
                n += 1;
                out[n] = '[';
                n += 1;
                out[n] = 'Z';
                n += 1;
            } else {
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
            }
        },
        .up, .down, .left, .right => {
            // Arrow keys: ESC [ A/B/C/D (no mods) or ESC [ 1 ; <mod> A/B/C/D (with mods)
            const dir_char: u8 = switch (@as(BindKeyKind, key)) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                else => unreachable,
            };

            out[n] = 0x1b;
            n += 1;
            out[n] = '[';
            n += 1;

            if (mods != 0) {
                // Convert our mods to CSI modifier parameter:
                // CSI mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
                // Our encoding: alt=1, ctrl=2, shift=4
                var csi_mod: u8 = 1;
                if ((mods & 4) != 0) csi_mod |= 1; // shift
                if ((mods & 1) != 0) csi_mod |= 2; // alt
                if ((mods & 2) != 0) csi_mod |= 4; // ctrl

                out[n] = '1';
                n += 1;
                out[n] = ';';
                n += 1;
                out[n] = '0' + csi_mod;
                n += 1;
            }

            out[n] = dir_char;
            n += 1;
        },
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
            .tap_pending, .hold, .hold_fired, .repeat_wait, .repeat_active, .repeat_locked, .delayed_press => return t.mods,
        }
    }
    return null;
}

fn scheduleTimer(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext) void {
    scheduleTimerFull(state, kind, deadline_ms, mods, key, action, focus_ctx, 0, false);
}

fn scheduleTimerWithStart(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext, press_start_ms: i64) void {
    scheduleTimerFull(state, kind, deadline_ms, mods, key, action, focus_ctx, press_start_ms, false);
}

fn scheduleTimerFull(state: *State, kind: State.PendingKeyTimerKind, deadline_ms: i64, mods: u8, key: BindKey, action: BindAction, focus_ctx: FocusContext, press_start_ms: i64, is_repeat: bool) void {
    state.key_timers.append(state.allocator, .{
        .kind = kind,
        .deadline_ms = deadline_ms,
        .mods = mods,
        .key = key,
        .action = action,
        .focus_ctx = focus_ctx,
        .press_start_ms = press_start_ms,
        .is_repeat = is_repeat,
    }) catch {};
}

pub fn processKeyTimers(state: *State, now_ms: i64) void {
    var i: usize = 0;
    while (i < state.key_timers.items.len) {
        const t = state.key_timers.items[i];
        if (t.kind == .hold_fired or t.kind == .repeat_wait or t.kind == .repeat_active or t.kind == .repeat_locked) {
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
            .tap_pending => {
                // Quick release timer expired without same key pressed again = TAP
                main.debugLog("tap_pending expired: firing action", .{});
                _ = dispatchAction(state, t.action);
            },
            .delayed_press => {
                _ = dispatchAction(state, t.action);
            },
            .hold_fired => {},
            .repeat_wait => {},
            .repeat_active => {},
            .repeat_locked => {},
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
            return dispatchBindWithMode(state, b, mods, key);
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

        // Find and remove hold timer, getting press_start_ms and is_repeat
        var had_hold_pending = false;
        var press_start_ms: i64 = 0;
        var was_repeat = false;
        i = 0;
        while (i < state.key_timers.items.len) {
            const t = state.key_timers.items[i];
            if (t.kind == .hold and t.mods == mods_eff and keyEq(t.key, key)) {
                press_start_ms = t.press_start_ms;
                was_repeat = t.is_repeat;
                _ = state.key_timers.orderedRemove(i);
                had_hold_pending = true;
                continue;
            }
            i += 1;
        }

        // Clean up repeat_active if any
        cancelTimer(state, .repeat_active, mods_eff, key);

        // Determine action based on press duration
        if (had_hold_pending) {
            const duration_ms = now_ms - press_start_ms;
            main.debugLog("release: mods_eff={d} key={any} duration={d}ms was_repeat={}", .{ mods_eff, key, duration_ms, was_repeat });

            // If this was part of a repeat sequence, don't fire tap
            if (was_repeat) {
                main.debugLog("release: was_repeat=true, not firing tap", .{});
                return true;
            }

            // Find the bind to use
            const maybe_bind = findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query);

            if (duration_ms >= cfg.input.tap_ms) {
                // 300ms+ = TAP - fire immediately
                main.debugLog("release: TAP (duration >= {d}ms)", .{cfg.input.tap_ms});
                if (maybe_bind) |b| {
                    _ = dispatchBindWithMode(state, b, mods_eff, key);
                } else {
                    forwardKeyToPane(state, mods_eff, key);
                }
            } else {
                // <300ms = quick release, defer to see if same key comes again (repeat)
                main.debugLog("release: quick (<{d}ms), scheduling tap_pending", .{cfg.input.tap_ms});
                if (maybe_bind) |b| {
                    // Schedule tap_pending - will fire action after tap_ms if no repeat
                    scheduleTimer(state, .tap_pending, now_ms + cfg.input.tap_ms, mods_eff, key, b.action, focus_ctx);
                } else {
                    // No bind - forward key to pane immediately (no repeat detection needed)
                    forwardKeyToPane(state, mods_eff, key);
                }
            }
            return true;
        }

        // Fire release bind if exists
        if (findBestBind(state, mods_eff, key, .release, allow_only_tabs, &query)) |b| {
            return dispatchBindWithMode(state, b, mods_eff, key);
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
        const repeat_timeout: i64 = 100; // Internal: terminal repeat event tracking
        var found = false;
        for (state.key_timers.items) |*t| {
            if (t.kind == .repeat_active and t.mods == mods_eff and keyEq(t.key, key)) {
                t.deadline_ms = now_ms + repeat_timeout;
                found = true;
                break;
            }
        }
        if (!found) {
            scheduleTimer(state, .repeat_active, now_ms + repeat_timeout, mods_eff, key, .mux_quit, focus_ctx);
        }

        // Fire repeat bind ONLY if explicitly defined - no fallback to press
        // This ensures keybinds only trigger on TAP (press+release), not on hold/repeat
        if (findBestBind(state, mods_eff, key, .repeat, allow_only_tabs, &query)) |b| {
            return dispatchBindWithMode(state, b, mods_eff, key);
        }
        // No repeat bind - check if there's any other binding for this key
        if (mods_eff != 0) {
            const has_press = findBestBind(state, mods_eff, key, .press, false, &query) != null;
            const has_hold = findBestBind(state, mods_eff, key, .hold, false, &query) != null;
            const has_release = findBestBind(state, mods_eff, key, .release, false, &query) != null;
            if (has_press or has_hold or has_release) {
                // Has other bindings - consume repeat to prevent re-triggering
                return true;
            }
            // No bindings at all - let repeat pass through
            return false;
        }
        return false; // Forward repeat to pane for unmodified keys
    }

    // --- PRESS ---
    if (when == .press) {
        // Debug: log all Ctrl+Alt presses
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char) {
            main.debugLog("press: Ctrl+Alt+{c} (0x{x})", .{ key.char, key.char });
        }

        // Check for repeat_locked - if same key, still in repeat mode; if different key, exit repeat mode
        var in_repeat_mode = false;
        var i: usize = 0;
        while (i < state.key_timers.items.len) {
            const t = state.key_timers.items[i];
            if (t.kind == .repeat_locked) {
                if (t.mods == mods_eff and keyEq(t.key, key)) {
                    // Same key - still in repeat mode
                    in_repeat_mode = true;
                    main.debugLog("press: repeat_locked for same key, still REPEAT", .{});
                    i += 1;
                } else {
                    // Different key - exit repeat mode
                    main.debugLog("press: repeat_locked for different key, exiting repeat mode", .{});
                    _ = state.key_timers.orderedRemove(i);
                    // Don't increment i, continue checking
                }
                continue;
            }
            i += 1;
        }

        // Check if there's a tap_pending for this key - rapid press = entering REPEAT mode
        var had_tap_pending = false;
        i = 0;
        while (i < state.key_timers.items.len) {
            const t = state.key_timers.items[i];
            if (t.kind == .tap_pending and t.mods == mods_eff and keyEq(t.key, key)) {
                _ = state.key_timers.orderedRemove(i);
                had_tap_pending = true;
                main.debugLog("press: found tap_pending, entering REPEAT mode", .{});
                continue;
            }
            i += 1;
        }

        if (had_tap_pending or in_repeat_mode) {
            // In repeat mode - don't trigger bind
            // Mark is_repeat=true so release also doesn't fire
            cancelTimer(state, .hold, mods_eff, key);
            scheduleTimerFull(state, .hold, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx, now_ms, true);
            // Lock this key combo in repeat mode (persists until different key pressed)
            if (had_tap_pending) {
                // Only schedule new repeat_locked when first entering repeat mode
                scheduleTimer(state, .repeat_locked, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx);
            }
            return true;
        }

        // Test: Ctrl+Alt+; press = arm hold timer for HOLD test
        if (mods_eff == 3 and @as(BindKeyKind, key) == .char and key.char == ';') {
            main.debugLog("test key matched, arming hold timer", .{});
            cancelTimer(state, .hold, mods_eff, key);
            cancelTimer(state, .hold_fired, mods_eff, key);
            // Arm hold timer - when it fires, show HOLD notification
            scheduleTimerWithStart(state, .hold, now_ms + cfg.input.hold_ms, mods_eff, key, .mux_quit, focus_ctx, now_ms);
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

        // For modified keys, only defer if there's an actual binding.
        // Keys without bindings should pass through raw to preserve escape sequences.
        if (mods_eff != 0) {
            // Check if ANY binding exists for this key+mods combo
            const has_press = findBestBind(state, mods_eff, key, .press, false, &query) != null;
            const has_hold = findBestBind(state, mods_eff, key, .hold, false, &query) != null;
            const has_release = findBestBind(state, mods_eff, key, .release, false, &query) != null;

            if (!has_press and !has_hold and !has_release) {
                // No bindings - don't consume, let raw input pass through
                return false;
            }

            main.debugLog("press defer: mods_eff={d} key={any}", .{ mods_eff, key });
            if (findBestBind(state, mods_eff, key, .hold, false, &query)) |hb| {
                const hold_ms = hb.hold_ms orelse cfg.input.hold_ms;
                cancelTimer(state, .hold, mods_eff, key);
                cancelTimer(state, .hold_fired, mods_eff, key);
                scheduleTimerWithStart(state, .hold, now_ms + hold_ms, mods_eff, key, hb.action, focus_ctx, now_ms);
            } else {
                // Has press/release bind but no hold - arm dummy hold timer to defer until release
                cancelTimer(state, .hold, mods_eff, key);
                scheduleTimerWithStart(state, .hold, std.math.maxInt(i64), mods_eff, key, .mux_quit, focus_ctx, now_ms);
            }
            return true; // Wait for release
        }

        // Unmodified keys - fire press immediately
        if (findBestBind(state, mods_eff, key, .press, allow_only_tabs, &query)) |b| {
            return dispatchBindWithMode(state, b, mods_eff, key);
        }
    }

    return false;
}

/// Dispatch a bind action respecting its mode setting.
/// Returns true if key should be consumed, false if it should passthrough.
fn dispatchBindWithMode(state: *State, bind: core.Config.Bind, mods: u8, key: BindKey) bool {
    switch (bind.mode) {
        .passthrough_only => {
            // Don't execute action, just pass the key through
            forwardKeyToPane(state, mods, key);
            return true; // Return true so we don't double-forward
        },
        .act_and_passthrough => {
            // Execute action AND pass the key to pane
            _ = dispatchAction(state, bind.action);
            forwardKeyToPane(state, mods, key);
            return true; // Return true so we don't double-forward
        },
        .act_and_consume => {
            // Execute action and consume (default behavior)
            return dispatchAction(state, bind.action);
        },
    }
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
        .sprite_toggle => {
            // Toggle sprite on the focused pane - use the pane's actual Pokemon name!
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    const pane = state.floats.items[idx];
                    if (pane.pokemon_initialized) {
                        if (pane.pokemon_state.show_sprite) {
                            pane.pokemon_state.hide();
                        } else {
                            // Get the pane's Pokemon name from pane_names cache
                            const pokemon_name = state.pane_names.get(pane.uuid) orelse "pikachu";

                            pane.pokemon_state.loadSprite(pokemon_name, false) catch {
                                // Fallback to pikachu if loading fails
                                pane.pokemon_state.loadSprite("pikachu", false) catch {};
                            };
                        }
                        state.needs_render = true;
                    }
                }
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                if (pane.pokemon_initialized) {
                    if (pane.pokemon_state.show_sprite) {
                        pane.pokemon_state.hide();
                    } else {
                        // Get the pane's Pokemon name from pane_names cache
                        const pokemon_name = state.pane_names.get(pane.uuid) orelse "pikachu";

                        pane.pokemon_state.loadSprite(pokemon_name, false) catch {
                            pane.pokemon_state.loadSprite("pikachu", false) catch {};
                        };
                    }
                    state.needs_render = true;
                }
            }
            return true;
        },
        .split_h => {
            const parent_uuid = state.getCurrentFocusedUuid();
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to mux's CWD if pane CWD unavailable
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch null;
            }
            if (state.currentLayout().splitFocused(.horizontal, cwd) catch null) |new_pane| {
                state.syncPaneAux(new_pane, parent_uuid);
            }
            state.needs_render = true;
            state.syncStateToSes();
            return true;
        },
        .split_v => {
            const parent_uuid = state.getCurrentFocusedUuid();
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to mux's CWD if pane CWD unavailable
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch null;
            }
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
            actions.switchToNextTab(state);
            return true;
        },
        .tab_prev => {
            actions.switchToPrevTab(state);
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
