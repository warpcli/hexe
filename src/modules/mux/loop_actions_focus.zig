const std = @import("std");
const core = @import("core");
const pop = @import("pop");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

/// Enter pane select mode - displays numbered labels on all panes.
/// If swap is true, selecting a pane will swap it with the focused pane.
/// If swap is false, selecting a pane will just focus it.
pub fn enterPaneSelectMode(state: *State, swap: bool) void {
    state.overlays.enterPaneSelectMode(swap);

    var label_idx: usize = 0;

    const layout = state.currentLayout();
    var pane_iter = layout.splits.valueIterator();
    while (pane_iter.next()) |pane_ptr| {
        const pane = pane_ptr.*;
        if (pop.overlay.labelForIndex(label_idx)) |label| {
            state.overlays.addPaneLabel(
                pane.uuid,
                label,
                pane.x,
                pane.y,
                pane.width,
                pane.height,
            );
            label_idx += 1;
        } else break;
    }

    for (state.floats.items) |pane| {
        if (!pane.isVisibleOnTab(state.active_tab)) continue;
        if (pane.parent_tab) |parent| {
            if (parent != state.active_tab) continue;
        }

        if (pop.overlay.labelForIndex(label_idx)) |label| {
            state.overlays.addPaneLabel(
                pane.uuid,
                label,
                pane.x,
                pane.y,
                pane.width,
                pane.height,
            );
            label_idx += 1;
        } else break;
    }

    state.needs_render = true;
}

/// Focus a pane by UUID. Works for both split panes and floats.
pub fn focusPaneByUuid(state: *State, uuid: [32]u8) void {
    for (state.floats.items, 0..) |pane, i| {
        if (std.mem.eql(u8, &pane.uuid, &uuid)) {
            if (!pane.isVisibleOnTab(state.active_tab)) continue;
            if (pane.parent_tab) |parent| {
                if (parent != state.active_tab) continue;
            }

            state.unfocusAllPanes();
            state.active_floating = i;
            pane.focused = true;
            state.syncPaneFocus(pane, null);
            state.needs_render = true;
            return;
        }
    }

    const layout = state.currentLayout();
    var it = layout.splits.iterator();
    while (it.next()) |entry| {
        const pane = entry.value_ptr.*;
        if (std.mem.eql(u8, &pane.uuid, &uuid)) {
            state.unfocusAllPanes();
            state.active_floating = null;
            layout.focused_split_id = entry.key_ptr.*;
            pane.focused = true;
            state.syncPaneFocus(pane, null);
            state.needs_render = true;
            return;
        }
    }
}

/// Handle input when pane select mode is active.
/// Returns true if input was consumed.
/// - Lowercase (a-z): Focus that pane
/// - Uppercase (A-Z): Swap focused pane position with target
/// - ESC: Cancel
pub fn handlePaneSelectInput(state: *State, byte: u8) bool {
    if (!state.overlays.isPaneSelectActive()) return false;

    if (byte == 0x1b) {
        state.overlays.exitPaneSelectMode();
        state.needs_render = true;
        return true;
    }

    const is_swap = byte >= 'A' and byte <= 'Z';
    const label: u8 = if (is_swap) byte + 32 else byte;
    if (label < 'a' or label > 'z') return true;

    if (state.overlays.findPaneByLabel(label)) |target_uuid| {
        if (is_swap) {
            const focused = getCurrentFocusedPane(state);
            const target = state.findPaneByUuid(target_uuid);
            if (focused != null and target != null and focused.? != target.?) {
                swapPanePositions(state, focused.?, target.?);
            }
        } else {
            focusPaneByUuid(state, target_uuid);
        }
        state.overlays.exitPaneSelectMode();
        state.needs_render = true;
        return true;
    }

    return true;
}

/// Switch to the next tab, handling focus transitions.
/// Does NOT wrap around - stays on last tab if already there.
pub fn switchToNextTab(state: *State) void {
    if (state.tabs.items.len <= 1) return;
    if (state.active_tab >= state.tabs.items.len - 1) return;

    const old_uuid = state.getCurrentFocusedUuid();

    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) {
            const fp = state.floats.items[idx];
            state.syncPaneUnfocus(fp);
            state.active_floating = null;
            state.cursor_needs_restore = true;
        }
    } else if (state.currentLayout().getFocusedPane()) |old_pane| {
        state.syncPaneUnfocus(old_pane);
    }

    state.active_tab += 1;
    restoreFocusInTab(state, old_uuid);
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

/// Switch to the previous tab, handling focus transitions.
/// Does NOT wrap around - stays on first tab if already there.
pub fn switchToPrevTab(state: *State) void {
    if (state.tabs.items.len <= 1) return;
    if (state.active_tab == 0) return;

    const old_uuid = state.getCurrentFocusedUuid();

    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) {
            const fp = state.floats.items[idx];
            state.syncPaneUnfocus(fp);
            state.active_floating = null;
            state.cursor_needs_restore = true;
        }
    } else if (state.currentLayout().getFocusedPane()) |old_pane| {
        state.syncPaneUnfocus(old_pane);
    }

    state.active_tab -= 1;
    restoreFocusInTab(state, old_uuid);
    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

fn getCurrentFocusedPane(state: *State) ?*Pane {
    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) return state.floats.items[idx];
    }
    return state.currentLayout().getFocusedPane();
}

fn swapPanePositions(state: *State, pane_a: *Pane, pane_b: *Pane) void {
    if (pane_a == pane_b) return;

    const a_float = pane_a.floating;
    const b_float = pane_b.floating;

    if (!a_float and !b_float) {
        const layout = state.currentLayout();

        var key_a: ?u16 = null;
        var key_b: ?u16 = null;
        var it = layout.splits.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == pane_a) key_a = entry.key_ptr.*;
            if (entry.value_ptr.* == pane_b) key_b = entry.key_ptr.*;
        }
        if (key_a == null or key_b == null) return;

        const ptr_a = layout.splits.getPtr(key_a.?) orelse return;
        const ptr_b = layout.splits.getPtr(key_b.?) orelse return;
        ptr_a.* = pane_b;
        ptr_b.* = pane_a;

        const tmp_id = pane_a.id;
        pane_a.id = pane_b.id;
        pane_b.id = tmp_id;

        if (layout.focused_split_id == key_a.?) {
            layout.focused_split_id = key_b.?;
        } else if (layout.focused_split_id == key_b.?) {
            layout.focused_split_id = key_a.?;
        }

        layout.recalculateLayout();
    } else if (a_float and b_float) {
        swapFloatPositions(pane_a, pane_b);
    } else {
        state.notifications.show("Cannot swap split with float");
        return;
    }

    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

fn swapFloatPositions(a: *Pane, b: *Pane) void {
    const ax = a.x;
    const ay = a.y;
    const aw = a.width;
    const ah = a.height;
    a.x = b.x;
    a.y = b.y;
    a.width = b.width;
    a.height = b.height;
    b.x = ax;
    b.y = ay;
    b.width = aw;
    b.height = ah;

    const abx = a.border_x;
    const aby = a.border_y;
    const abw = a.border_w;
    const abh = a.border_h;
    a.border_x = b.border_x;
    a.border_y = b.border_y;
    a.border_w = b.border_w;
    a.border_h = b.border_h;
    b.border_x = abx;
    b.border_y = aby;
    b.border_w = abw;
    b.border_h = abh;

    const awp = a.float_width_pct;
    const ahp = a.float_height_pct;
    const axp = a.float_pos_x_pct;
    const ayp = a.float_pos_y_pct;
    const apx = a.float_pad_x;
    const apy = a.float_pad_y;
    a.float_width_pct = b.float_width_pct;
    a.float_height_pct = b.float_height_pct;
    a.float_pos_x_pct = b.float_pos_x_pct;
    a.float_pos_y_pct = b.float_pos_y_pct;
    a.float_pad_x = b.float_pad_x;
    a.float_pad_y = b.float_pad_y;
    b.float_width_pct = awp;
    b.float_height_pct = ahp;
    b.float_pos_x_pct = axp;
    b.float_pos_y_pct = ayp;
    b.float_pad_x = apx;
    b.float_pad_y = apy;

    a.vt.resize(a.width, a.height) catch {};
    b.vt.resize(b.width, b.height) catch {};

    switch (a.backend) {
        .local => |*pty| pty.setSize(a.width, a.height) catch {},
        .pod => |pod| {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u16, payload[0..2], a.width, .big);
            std.mem.writeInt(u16, payload[2..4], a.height, .big);
            const ft = @intFromEnum(core.pod_protocol.FrameType.resize);
            core.wire.writeMuxVt(pod.vt_fd, pod.pane_id, ft, &payload) catch {};
        },
    }
    switch (b.backend) {
        .local => |*pty| pty.setSize(b.width, b.height) catch {},
        .pod => |pod| {
            var payload: [4]u8 = undefined;
            std.mem.writeInt(u16, payload[0..2], b.width, .big);
            std.mem.writeInt(u16, payload[2..4], b.height, .big);
            const ft = @intFromEnum(core.pod_protocol.FrameType.resize);
            core.wire.writeMuxVt(pod.vt_fd, pod.pane_id, ft, &payload) catch {};
        },
    }
}

fn restoreFocusInTab(state: *State, old_uuid: ?[32]u8) void {
    if (state.tab_last_focus_kind.items.len > state.active_tab and
        state.tab_last_focus_kind.items[state.active_tab] == .float)
    {
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
                    return;
                }
            }
        }
    }

    if (state.currentLayout().getFocusedPane()) |new_pane| {
        state.syncPaneFocus(new_pane, old_uuid);
    }
}
