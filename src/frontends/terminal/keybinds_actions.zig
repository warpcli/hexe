const std = @import("std");
const core = @import("core");

const layout_mod = @import("layout.zig");
const actions = @import("loop_actions.zig");
const focus_move = @import("focus_move.zig");
const mouse_selection = @import("mouse_selection.zig");

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;

const BindAction = core.Config.BindAction;

pub fn dispatchAction(state: *State, action: BindAction) bool {
    const cfg = &state.config;

    switch (action) {
        .mux_quit => {
            if (cfg.confirm_on_exit) {
                _ = state.showConfirmOrNotify(.exit, "Exit terminal session?");
            } else {
                state.running = false;
            }
            return true;
        },
        .pane_disown => {
            const current_pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
                state.view.float_views.items[idx]
            else
                state.currentLayout().getFocusedPane();

            if (current_pane) |p| {
                if (state.paneSticky(p)) {
                    state.notifications.show("Cannot disown sticky float");
                    state.needs_render = true;
                    return true;
                }
            }

            if (cfg.confirm_on_disown) {
                _ = state.showConfirmOrNotify(.disown, "Disown pane?");
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
        .clipboard_copy => {
            const pane: ?*Pane = if (state.activeFloatingIndex()) |idx|
                state.view.float_views.items[idx]
            else
                state.currentLayout().getFocusedPane();

            const p = pane orelse {
                state.notifications.showFor("No focused pane", 1200);
                state.needs_render = true;
                return true;
            };

            const range = state.mouse_selection.bufRangeForPane(state.activeTabIndex(), p) orelse {
                state.notifications.showFor("No text selected", 1200);
                state.needs_render = true;
                return true;
            };

            const bytes = mouse_selection.extractText(state.allocator, p, range) catch {
                state.notifications.showFor("Copy failed", 1200);
                state.needs_render = true;
                return true;
            };
            defer state.allocator.free(bytes);

            if (bytes.len == 0) {
                state.notifications.showFor("No text selected", 1200);
                state.needs_render = true;
                return true;
            }

            const stdout = std.fs.File.stdout();
            var io_buf: [256]u8 = undefined;
            var writer = stdout.writer(&io_buf);
            state.renderer.vx.copyToSystemClipboard(&writer.interface, bytes, state.allocator) catch {
                state.notifications.showFor("Clipboard copy failed", 1200);
                state.needs_render = true;
                return true;
            };

            state.notifications.showFor("Copied selection", 1200);
            state.needs_render = true;
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
        .system_notify => {
            const stdout = std.fs.File.stdout();
            var io_buf: [512]u8 = undefined;
            var writer = stdout.writer(&io_buf);

            const body = if (state.view.tab_views.items.len > 0 and state.activeTabIndex() < state.view.tab_views.items.len)
                (state.runtime.tabName(state.activeTabIndex()) orelse "tab")
            else
                "hexe";

            state.renderer.vx.notify(&writer.interface, "hexe", body) catch {
                state.notifications.showFor("Notification send failed", 1200);
                state.needs_render = true;
                return true;
            };
            state.notifications.showFor("Notification sent", 900);
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
            if (state.activeFloatingIndex()) |idx| {
                if (idx < state.view.float_views.items.len) {
                    const pane = state.view.float_views.items[idx];
                    if (pane.pokemon_initialized) {
                        if (pane.pokemon_state.show_sprite) {
                            pane.pokemon_state.hide();
                        } else {
                            // Get the pane's Pokemon name from pane_names cache
                            const pokemon_name = state.paneName(pane.uuid) orelse "pikachu";

                            pane.pokemon_state.loadSprite(pokemon_name, false) catch {
                                // Fallback to pikachu if loading fails
                                pane.pokemon_state.loadSprite("pikachu", false) catch |err| {
                                    core.logging.logError("terminal", "failed to load fallback sprite for focused float", err);
                                };
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
                        const pokemon_name = state.paneName(pane.uuid) orelse "pikachu";

                        pane.pokemon_state.loadSprite(pokemon_name, false) catch {
                            pane.pokemon_state.loadSprite("pikachu", false) catch |err| {
                                core.logging.logError("terminal", "failed to load fallback sprite for focused pane", err);
                            };
                        };
                    }
                    state.needs_render = true;
                }
            }
            return true;
        },
        .split_h => {
            // Prevent split creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            const parent_pane = state.currentLayout().getFocusedPane() orelse {
                core.logging.warn("terminal", "split_h skipped: no focused pane", .{});
                return true;
            };
            const parent_uuid = parent_pane.uuid;
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to the terminal process CWD if pane CWD is unavailable.
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                    core.logging.logError("terminal", "split_h: failed to get fallback cwd", err);
                    break :blk null;
                };
            }
            const new_pane = state.currentLayout().splitFocused(.horizontal, cwd) catch |err| blk: {
                core.logging.logError("terminal", "split_h failed to create pane", err);
                state.notifications.show("Split failed: pane creation error");
                break :blk null;
            };
            if (new_pane) |pane| {
                if (state.syncSessionSplitPaneChecked(parent_uuid, pane.uuid, .horizontal, pane.uuid)) {
                    state.syncPaneAux(pane, parent_uuid);
                } else {
                    _ = state.currentLayout().closePane(pane.uuid);
                    state.notifications.show("Split failed: session sync rejected pane");
                }
            }
            state.needs_render = true;
            return true;
        },
        .split_v => {
            // Prevent split creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            const parent_pane = state.currentLayout().getFocusedPane() orelse {
                core.logging.warn("terminal", "split_v skipped: no focused pane", .{});
                return true;
            };
            const parent_uuid = parent_pane.uuid;
            var cwd: ?[]const u8 = null;
            if (state.currentLayout().getFocusedPane()) |p| {
                cwd = state.getReliableCwd(p);
            }
            // Fallback to the terminal process CWD if pane CWD is unavailable.
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (cwd == null) {
                cwd = std.posix.getcwd(&cwd_buf) catch |err| blk: {
                    core.logging.logError("terminal", "split_v: failed to get fallback cwd", err);
                    break :blk null;
                };
            }
            const new_pane = state.currentLayout().splitFocused(.vertical, cwd) catch |err| blk: {
                core.logging.logError("terminal", "split_v failed to create pane", err);
                state.notifications.show("Split failed: pane creation error");
                break :blk null;
            };
            if (new_pane) |pane| {
                if (state.syncSessionSplitPaneChecked(parent_uuid, pane.uuid, .vertical, pane.uuid)) {
                    state.syncPaneAux(pane, parent_uuid);
                } else {
                    _ = state.currentLayout().closePane(pane.uuid);
                    state.notifications.show("Split failed: session sync rejected pane");
                }
            }
            state.needs_render = true;
            return true;
        },
        .split_resize => |dir_kind| {
            // Only applies to split panes (floats should ignore).
            if (state.activeFloatingIndex() != null) return true;
            const dir: ?layout_mod.Layout.Direction = switch (dir_kind) {
                .up => .up,
                .down => .down,
                .left => .left,
                .right => .right,
                else => null,
            };
            if (dir == null) return true;
            if (state.currentLayout().resizeFocused(dir.?, 1)) |sync| {
                state.needs_render = true;
                state.renderer.invalidate();
                state.force_full_render = true;
                state.syncSessionSplitRatio(sync.first_anchor_uuid, sync.second_anchor_uuid, sync.ratio);
            }
            return true;
        },
        .tab_new => {
            // Prevent tab creation during detach (race prevention)
            if (state.isDetachMode()) {
                return true; // Silently ignore during detach
            }
            state.setActiveFloatingIndex(null);
            state.createTab() catch |e| {
                core.logging.logError("terminal", "createTab failed", e);
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
            if (state.activeFloatingIndex() != null) {
                // Close the focused float.
                if (cfg.confirm_on_close) {
                    _ = state.showConfirmOrNotify(.close, "Close float?");
                } else {
                    actions.performClose(state);
                }
            } else {
                // Close split pane if there are multiple splits.
                const layout = state.currentLayout();
                if (layout.splitCount() > 1) {
                    if (cfg.confirm_on_close) {
                        _ = state.showConfirmOrNotify(.pane_close, "Close pane?");
                    } else {
                        const closing_pane = layout.getFocusedPane().?;
                        const closing_uuid = closing_pane.uuid;
                        state.runtime.killPane(closing_uuid) catch |err| {
                            core.logging.logError("terminal", "killPane failed before split close", err);
                            state.notifications.show("Close pane failed: session rejected pane kill");
                            state.needs_render = true;
                            return true;
                        };
                        state.clearTransientPaneState(closing_pane);
                        _ = layout.closePaneLocal(closing_uuid);
                        if (layout.getFocusedPane()) |new_pane| {
                            state.syncPaneFocus(new_pane, null);
                        }
                        state.needs_render = true;
                    }
                }
                // If only one pane, do nothing (don't close the tab).
            }
            return true;
        },
        .tab_close => {
            if (cfg.confirm_on_close) {
                const msg = if (state.activeFloatingIndex() != null) "Close float?" else "Close tab?";
                _ = state.showConfirmOrNotify(.close, msg);
            } else {
                actions.performClose(state);
            }
            return true;
        },
        .mux_detach => {
            if (cfg.confirm_on_detach) {
                _ = state.showConfirmOrNotify(.detach, "Detach session?");
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
            const fi = state.activeFloatingIndex() orelse {
                core.logging.warn("terminal", "float_nudge skipped: no active float", .{});
                return false;
            };
            if (fi >= state.view.float_views.items.len) {
                core.logging.warn("terminal", "float_nudge skipped: active float index is out of range", .{});
                return false;
            }
            const pane = state.view.float_views.items[fi];
            if (state.paneParentTab(pane)) |parent| {
                if (parent != state.activeTabIndex()) {
                    core.logging.warn("terminal", "float_nudge skipped: active float belongs to another tab", .{});
                    return false;
                }
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
        .layout_save => {
            _ = state.showPickerOrNotify(
                .layout_save_choose,
                &.{ "local", "global", "both" },
                "Save layout scope",
            );
            return true;
        },
        .layout_load => {
            if (std.fs.cwd().access(".hexe.lua", .{})) |_| {} else |_| {
                state.notifications.showFor("No local .hexe.lua", 1400);
                state.needs_render = true;
                return true;
            }

            _ = state.showPickerOrNotify(
                .layout_load_choose,
                &.{ "detach", "replace" },
                "Load local layout: detach or replace",
            );
            return true;
        },
    }
}

fn nudgeFloat(state: *State, pane: *Pane, dir: layout_mod.Layout.Direction, step_cells: u16) void {
    const frame = state.floatFrameForPane(pane);
    const max_x: u16 = frame.max_x;
    const max_y: u16 = frame.max_y;

    var outer_x: i32 = @intCast(state.paneBorderX(pane));
    var outer_y: i32 = @intCast(state.paneBorderY(pane));
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
    const pos_x_pct: u8 = if (max_x > 0)
        @intCast(@min(100, (@as(u32, @intCast(outer_x)) * 100) / @as(u32, max_x)))
    else
        0;
    const pos_y_pct: u8 = if (max_y > 0)
        @intCast(@min(100, (@as(u32, @intCast(outer_y)) * 100) / @as(u32, max_y)))
    else
        0;
    state.setPaneFloatGeometryUi(
        pane.uuid,
        state.paneFloatWidthPct(pane),
        state.paneFloatHeightPct(pane),
        pos_x_pct,
        pos_y_pct,
        state.paneFloatPadX(pane),
        state.paneFloatPadY(pane),
    );

    state.resizeFloatingPanes();
}
