const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");
const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const BindAction = core.Config.BindAction;

pub fn dispatchAction(state: *State, action: BindAction) bool {
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
        .clipboard_request => {
            const stdout = std.fs.File.stdout();
            var buf: [256]u8 = undefined;
            var writer = stdout.writer(&buf);
            state.renderer.vx.requestSystemClipboard(&writer.interface) catch {
                state.notifications.showFor("Clipboard request failed", 1200);
                state.needs_render = true;
                return true;
            };
            state.notifications.showFor("Requested clipboard", 900);
            state.needs_render = true;
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
            // Prevent split creation during detach (race prevention)
            if (state.detach_mode) {
                return true; // Silently ignore during detach
            }
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
            // Prevent split creation during detach (race prevention)
            if (state.detach_mode) {
                return true; // Silently ignore during detach
            }
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
            // Prevent tab creation during detach (race prevention)
            if (state.detach_mode) {
                return true; // Silently ignore during detach
            }
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
