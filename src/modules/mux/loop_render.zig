const std = @import("std");

const State = @import("state.zig").State;
const CursorInfo = @import("render_core.zig").CursorInfo;

const statusbar = @import("statusbar.zig");
const popup_render = @import("popup_render.zig");
const borders = @import("borders.zig");
const mouse_selection = @import("mouse_selection.zig");
const float_title = @import("float_title.zig");
const overlay_render = @import("overlay_render.zig");
const notification = @import("notification.zig");
const render_vx = @import("render_vx.zig");
const vt_bridge = @import("vt_bridge.zig");
const render_sprite = @import("render_sprite.zig");

fn drawPaneRenderState(renderer: anytype, state: anytype, x: u16, y: u16, width: u16, height: u16) void {
    const root = renderer.vx.window();
    const win = root.child(.{
        .x_off = @intCast(x),
        .y_off = @intCast(y),
        .width = width,
        .height = height,
    });
    vt_bridge.drawRenderState(win, state, width, height, renderer.frame_arena.allocator());
}

fn sanitizeLabelUtf8(raw: []const u8, out: *[128]u8) []const u8 {
    var wi: usize = 0;
    var i: usize = 0;
    while (i < raw.len and wi < out.len) {
        const b = raw[i];

        // Strip ANSI/VT escape sequences so raw terminal control bytes never
        // leak into float titles.
        if (b == 0x1b) {
            i += 1;
            if (i >= raw.len) break;
            const esc = raw[i];

            // CSI: ESC [ ... final
            if (esc == '[') {
                i += 1;
                while (i < raw.len) : (i += 1) {
                    const c = raw[i];
                    if (c >= 0x40 and c <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
                continue;
            }

            // OSC: ESC ] ... BEL or ST (ESC \)
            if (esc == ']') {
                i += 1;
                while (i < raw.len) {
                    const c = raw[i];
                    if (c == 0x07) {
                        i += 1;
                        break;
                    }
                    if (c == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            // DCS/PM/APC: ESC P/^/_ ... ST (ESC \)
            if (esc == 'P' or esc == '^' or esc == '_') {
                i += 1;
                while (i < raw.len) {
                    if (raw[i] == 0x1b and i + 1 < raw.len and raw[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
                continue;
            }

            // Other escape forms are 2-byte sequences.
            i += 1;
            continue;
        }

        // C1 controls (including 0x9B CSI) are never valid label content.
        if (b >= 0x80 and b <= 0x9f) {
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const end = @min(i + len, raw.len);
        const chunk = raw[i..end];
        const cp = std.unicode.utf8Decode(chunk) catch {
            i = end;
            continue;
        };

        // Skip control characters.
        if (cp < 32 or cp == 127) {
            i = end;
            continue;
        }

        if (wi + chunk.len > out.len) break;
        @memcpy(out[wi .. wi + chunk.len], chunk);
        wi += chunk.len;
        i = end;
    }
    return out[0..wi];
}

pub fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame.
    renderer.vx.screen.clear();

    // Draw splits into the cell buffer.
    var pane_it = state.currentLayout().splitIterator();
    while (pane_it.next()) |pane| {
        const render_state = pane.*.getRenderState() catch continue;
        drawPaneRenderState(renderer, render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height);

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
            notification.renderInBounds(&pane.*.notifications, renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, false);
        }

        // Draw sprite overlay if enabled
        if (pane.*.pokemon_initialized and pane.*.pokemon_state.show_sprite) {
            if (pane.*.pokemon_state.sprite_content) |content| {
                render_sprite.drawSpriteOverlay(renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, content, state.pop_config.widgets.pokemon);
            }
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

        const float_label_raw = if (pane.float_title) |t|
            t
        else if (state.pane_names.get(pane.uuid)) |n|
            n
        else
            "";
        var float_label_buf: [128]u8 = undefined;
        const float_label = sanitizeLabelUtf8(float_label_raw, &float_label_buf);
        borders.drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, false, float_label, pane.border_color, pane.float_style);
        if (state.float_rename_uuid) |uuid| {
            if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                float_title.drawTitleEditor(renderer, pane, state.float_rename_buf.items);
            }
        }

        const render_state = pane.getRenderState() catch continue;
        drawPaneRenderState(renderer, render_state, pane.x, pane.y, pane.width, pane.height);

        if (state.mouse_selection.rangeForPane(state.active_tab, pane)) |range| {
            mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.x, pane.y, pane.width, pane.height, range, state.config.selection_color);
        }

        if (pane.isScrolled()) {
            borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane).
        if (pane.hasActiveNotification()) {
            notification.renderInBounds(&pane.notifications, renderer, pane.x, pane.y, pane.width, pane.height, false);
        }

        // Draw sprite overlay if enabled
        if (pane.pokemon_initialized and pane.pokemon_state.show_sprite) {
            if (pane.pokemon_state.sprite_content) |content| {
                render_sprite.drawSpriteOverlay(renderer, pane.x, pane.y, pane.width, pane.height, content, state.pop_config.widgets.pokemon);
            }
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
            const active_float_label_raw = if (pane.float_title) |t|
                t
            else if (state.pane_names.get(pane.uuid)) |n|
                n
            else
                "";
            var active_float_label_buf: [128]u8 = undefined;
            const active_float_label = sanitizeLabelUtf8(active_float_label_raw, &active_float_label_buf);
            borders.drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, true, active_float_label, pane.border_color, pane.float_style);
            if (state.float_rename_uuid) |uuid| {
                if (std.mem.eql(u8, &uuid, &pane.uuid)) {
                    float_title.drawTitleEditor(renderer, pane, state.float_rename_buf.items);
                }
            }

            if (pane.getRenderState()) |render_state| {
                drawPaneRenderState(renderer, render_state, pane.x, pane.y, pane.width, pane.height);

                if (state.mouse_selection.rangeForPane(state.active_tab, pane)) |range| {
                    mouse_selection.applyOverlayTrimmed(renderer, render_state, pane.x, pane.y, pane.width, pane.height, range, state.config.selection_color);
                }
            } else |_| {}

            if (pane.isScrolled()) {
                borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
            }

            // Draw pane-local notification (PANE realm - bottom of pane).
            if (pane.hasActiveNotification()) {
                notification.renderInBounds(&pane.notifications, renderer, pane.x, pane.y, pane.width, pane.height, false);
            }

            // Draw sprite overlay if enabled
            if (pane.pokemon_initialized and pane.pokemon_state.show_sprite) {
                if (pane.pokemon_state.sprite_content) |content| {
                    render_sprite.drawSpriteOverlay(renderer, pane.x, pane.y, pane.width, pane.height, content, state.pop_config.widgets.pokemon);
                }
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
            popup_render.drawInBounds(renderer, popup, &state.pop_config.pane, pane.*.x, pane.*.y, pane.*.width, pane.*.height);
        }
    }
    // Check all floats.
    for (state.floats.items) |fpane| {
        if (fpane.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.pane, fpane.x, fpane.y, fpane.width, fpane.height);
        }
    }
    if (current_tab.notifications.hasActive()) {
        // TAB notifications render in center area (distinct from MUX at top).
        notification.renderInBounds(&current_tab.notifications, renderer, 0, 0, state.term_width, state.layout_height, true);
    }

    // Draw TAB-level blocking popup (below MUX popup).
    if (current_tab.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Draw MUX realm notifications overlay (top of screen).
    notification.renderFull(&state.notifications, renderer, state.term_width, state.term_height);

    // Draw MUX-level blocking popup overlay (on top of everything).
    if (state.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Gather cursor info.
    var cursor = CursorInfo{};

    if (state.active_floating) |idx| {
        const pane = state.floats.items[idx];
        const pos = pane.getCursorPos();
        cursor.x = pos.x;
        cursor.y = pos.y;
        cursor.style = pane.getCursorStyle();
        cursor.visible = pane.isCursorVisible();
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        const pos = pane.getCursorPos();
        cursor.x = pos.x;
        cursor.y = pos.y;
        cursor.style = pane.getCursorStyle();
        cursor.visible = pane.isCursorVisible();
    }

    // If cursor_needs_restore is set (e.g., after float death), force cursor visible
    if (state.cursor_needs_restore) {
        cursor.visible = true;
        state.cursor_needs_restore = false;
    }

    // End frame: render current vaxis screen.
    try render_vx.renderFrame(&renderer.vx, stdout, cursor, state.force_full_render);
    _ = renderer.frame_arena.reset(.retain_capacity);
    state.force_full_render = false;
}
