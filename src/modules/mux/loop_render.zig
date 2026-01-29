const std = @import("std");

const State = @import("state.zig").State;

const statusbar = @import("statusbar.zig");
const popup_render = @import("popup_render.zig");
const borders = @import("borders.zig");
const mouse_selection = @import("mouse_selection.zig");
const float_title = @import("float_title.zig");
const overlay_render = @import("overlay_render.zig");

pub fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame.
    renderer.beginFrame();

    // Draw splits into the cell buffer.
    var pane_it = state.currentLayout().splitIterator();
    while (pane_it.next()) |pane| {
        const render_state = pane.*.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height);

        if (state.mouse_selection.rangeForPane(state.active_tab, pane.*)) |range| {
            mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height, range, state.config.selection_color);
        }

        const is_scrolled = pane.*.isScrolled();

        // Draw scroll indicator if pane is scrolled.
        if (is_scrolled) {
            borders.drawScrollIndicator(renderer, pane.*.x, pane.*.y, pane.*.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane).
        if (pane.*.hasActiveNotification()) {
            pane.*.notifications.renderInBounds(renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, false);
        }
    }

    // Draw split borders when there are multiple splits.
    if (state.currentLayout().splitCount() > 1) {
        const content_height = state.term_height - state.status_height;
        borders.drawSplitBorders(renderer, state.currentLayout(), &state.config.splits, state.term_width, content_height);
    }

    // Draw visible floats (on top of splits).
    // Draw inactive floats first, then active one last so it's on top.
    for (state.floats.items, 0..) |pane, i| {
        if (!pane.isVisibleOnTab(state.active_tab)) continue;
        if (state.active_floating == i) continue; // Skip active, draw it last.
        // Skip tab-bound floats on wrong tab.
        if (pane.parent_tab) |parent| {
            if (parent != state.active_tab) continue;
        }

        borders.drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, false, if (pane.float_title) |t| t else "", pane.border_color, pane.float_style);
        if (state.float_rename_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                float_title.drawTitleEditor(renderer, pane, state.float_rename_buf.items);
            }
        }

        const render_state = pane.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);

        if (state.mouse_selection.rangeForPane(state.active_tab, pane)) |range| {
            mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.x, pane.y, pane.width, pane.height, range, state.config.selection_color);
        }

        if (pane.isScrolled()) {
            borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane).
        if (pane.hasActiveNotification()) {
            pane.notifications.renderInBounds(renderer, pane.x, pane.y, pane.width, pane.height, false);
        }
    }

    // Draw active float last so it's on top.
    if (state.active_floating) |idx| {
        const pane = state.floats.items[idx];
        // Check tab ownership for tab-bound floats.
        const can_render = if (pane.parent_tab) |parent|
            parent == state.active_tab
        else
            true;
        if (pane.isVisibleOnTab(state.active_tab) and can_render) {
            borders.drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, true, if (pane.float_title) |t| t else "", pane.border_color, pane.float_style);
            if (state.float_rename_uuid) |uuid| {
                if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                    float_title.drawTitleEditor(renderer, pane, state.float_rename_buf.items);
                }
            }

            if (pane.getRenderState()) |render_state| {
                renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);

                if (state.mouse_selection.rangeForPane(state.active_tab, pane)) |range| {
                    mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.x, pane.y, pane.width, pane.height, range, state.config.selection_color);
                }
            } else |_| {}

            if (pane.isScrolled()) {
                borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
            }

            // Draw pane-local notification (PANE realm - bottom of pane).
            if (pane.hasActiveNotification()) {
                pane.notifications.renderInBounds(renderer, pane.x, pane.y, pane.width, pane.height, false);
            }
        }
    }

    // Draw status bar if enabled.
    if (state.config.tabs.status.enabled) {
        statusbar.draw(renderer, state, state.allocator, &state.config, state.term_width, state.term_height, state.tabs, state.active_tab, state.session_name);
    }

    // Check if active float has dim_background set (focus mode)
    const float_dim = if (state.active_floating) |idx| blk: {
        if (idx < state.floats.items.len) break :blk state.floats.items[idx].dim_background;
        break :blk false;
    } else false;

    // Draw overlays (dimming, pane labels, resize info, keycast)
    if (state.overlays.hasContent() or state.overlays.shouldDim() or float_dim) {
        // Get focused pane bounds to exclude from dimming
        // For floats: use border dimensions + shadow (1 cell right/bottom) if shadow enabled
        const focused_bounds: ?overlay_render.Bounds = blk: {
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    const fp = state.floats.items[idx];
                    const has_shadow = if (fp.float_style) |s| s.shadow_color != null else false;
                    const shadow_offset: u16 = if (has_shadow) 1 else 0;
                    break :blk .{
                        .x = fp.border_x,
                        .y = fp.border_y,
                        .w = fp.border_w + shadow_offset,
                        .h = fp.border_h + shadow_offset,
                    };
                }
            }
            if (state.currentLayout().getFocusedPane()) |p| {
                break :blk .{ .x = p.x, .y = p.y, .w = p.width, .h = p.height };
            }
            break :blk null;
        };

        // Apply dimming for float focus mode (when overlays.shouldDim() is false)
        if (float_dim and !state.overlays.shouldDim()) {
            overlay_render.applyDimEffect(renderer, state.term_width, state.term_height, focused_bounds);
        }

        overlay_render.renderOverlays(renderer, &state.overlays, state.term_width, state.term_height, state.status_height, focused_bounds);
    }

    // Draw TAB realm notifications (center of screen, below MUX).
    const current_tab = &state.tabs.items[state.active_tab];

    // Draw PANE-level blocking popups (for ALL panes with active popups).
    // Check all splits in current tab.
    var split_iter = current_tab.layout.splits.valueIterator();
    while (split_iter.next()) |pane| {
        if (pane.*.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.carrier, pane.*.x, pane.*.y, pane.*.width, pane.*.height);
        }
    }
    // Check all floats.
    for (state.floats.items) |fpane| {
        if (fpane.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.carrier, fpane.x, fpane.y, fpane.width, fpane.height);
        }
    }
    if (current_tab.notifications.hasActive()) {
        // TAB notifications render in center area (distinct from MUX at top).
        current_tab.notifications.renderInBounds(renderer, 0, 0, state.term_width, state.layout_height, true);
    }

    // Draw TAB-level blocking popup (below MUX popup).
    if (current_tab.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Draw MUX realm notifications overlay (top of screen).
    state.notifications.render(renderer, state.term_width, state.term_height);

    // Draw MUX-level blocking popup overlay (on top of everything).
    if (state.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // End frame with differential render.
    const output = try renderer.endFrame(state.force_full_render);

    // Get cursor info.
    var cursor_x: u16 = 1;
    var cursor_y: u16 = 1;
    var cursor_style: u8 = 0;
    var cursor_visible: bool = true;

    if (state.active_floating) |idx| {
        const pane = state.floats.items[idx];
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor_x = pos.x + 1;
        cursor_y = pos.y + 1;
        cursor_style = pane.getCursorStyle();
        cursor_visible = pane.isCursorVisible();
    }

    // Build cursor sequences.
    var cursor_buf: [64]u8 = undefined;
    var cursor_len: usize = 0;

    const style_seq = std.fmt.bufPrint(cursor_buf[cursor_len..], "\x1b[{d} q", .{cursor_style}) catch "";
    cursor_len += style_seq.len;

    const pos_seq = std.fmt.bufPrint(cursor_buf[cursor_len..], "\x1b[{d};{d}H", .{ cursor_y, cursor_x }) catch "";
    cursor_len += pos_seq.len;

    if (cursor_visible) {
        const show_seq = "\x1b[?25h";
        @memcpy(cursor_buf[cursor_len..][0..show_seq.len], show_seq);
        cursor_len += show_seq.len;
    }

    // Write everything as a single iovec list.
    var iovecs = [_]std.posix.iovec_const{
        .{ .base = output.ptr, .len = output.len },
        .{ .base = &cursor_buf, .len = cursor_len },
    };
    try stdout.writevAll(iovecs[0..]);
}
