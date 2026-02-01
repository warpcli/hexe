const layout_mod = @import("layout.zig");
const focus_nav = @import("focus_nav.zig");
const State = @import("state.zig").State;
const actions = @import("loop_actions.zig");

/// Move focus across splits + floats in the given direction.
///
/// This is shared by both keybindings and IPC/CLI requests to avoid
/// dependency cycles between modules.
///
/// Behavior depends on current focus:
/// - Non-navigatable float: left/right switches tabs directly (up/down ignored)
/// - Navigatable float or split: directional navigation, tab switch at edge
pub fn perform(state: *State, dir: layout_mod.Layout.Direction) bool {
    // Check if we're on a non-navigatable float
    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) {
            const float_pane = state.floats.items[idx];
            if (!float_pane.navigatable) {
                // Non-navigatable float: left/right switches tabs, up/down ignored
                switch (dir) {
                    .left => actions.switchToPrevTab(state),
                    .right => actions.switchToNextTab(state),
                    .up, .down => {}, // Ignore vertical navigation
                }
                state.needs_render = true;
                return true;
            }
        }
    }

    // Navigatable float or split: use directional navigation
    const old_uuid = state.getCurrentFocusedUuid();
    const cursor = blk: {
        if (state.active_floating) |idx| {
            const pos = state.floats.items[idx].getCursorPos();
            break :blk @as(?layout_mod.CursorPos, .{ .x = pos.x, .y = pos.y });
        }
        if (state.currentLayout().getFocusedPane()) |pane| {
            const pos = pane.getCursorPos();
            break :blk @as(?layout_mod.CursorPos, .{ .x = pos.x, .y = pos.y });
        }
        break :blk @as(?layout_mod.CursorPos, null);
    };

    if (focus_nav.focusDirectionAny(state, dir, cursor)) |target| {
        if (target.kind == .float) {
            state.active_floating = target.float_index;
        } else {
            state.active_floating = null;
        }
        state.syncPaneFocus(target.pane, old_uuid);
        state.renderer.invalidate();
        state.force_full_render = true;
    } else {
        // No split/float found in that direction.
        // For left/right, switch to prev/next tab for seamless navigation.
        switch (dir) {
            .left => actions.switchToPrevTab(state),
            .right => actions.switchToNextTab(state),
            else => {},
        }
    }
    state.needs_render = true;
    return true;
}
