const layout_mod = @import("layout.zig");
const focus_nav = @import("focus_nav.zig");
const State = @import("state.zig").State;
const actions = @import("loop_actions.zig");

/// Move focus across splits + floats in the given direction.
///
/// This is shared by both keybindings and IPC/CLI requests to avoid
/// dependency cycles between modules.
///
/// For left/right: if no split/float is found in that direction,
/// automatically switch to the previous/next tab for seamless navigation.
pub fn perform(state: *State, dir: layout_mod.Layout.Direction) bool {
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
