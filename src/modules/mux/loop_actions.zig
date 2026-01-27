const std = @import("std");
const posix = std.posix;
const core = @import("core");

const layout_mod = @import("layout.zig");
const SplitDir = layout_mod.SplitDir;

const State = @import("state.zig").State;
const Pane = @import("pane.zig").Pane;
const SesClient = @import("ses_client.zig").SesClient;

const helpers = @import("helpers.zig");
const float_completion = @import("float_completion.zig");

fn escapeForShell(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');

    return out.toOwnedSlice(allocator);
}

fn mergeEnvLines(allocator: std.mem.Allocator, env: ?[]const []const u8, extra: ?[]const []const u8) !?[]const []const u8 {
    const env_len = if (env) |v| v.len else 0;
    const extra_len = if (extra) |v| v.len else 0;
    if (env_len + extra_len == 0) return null;
    const out = try allocator.alloc([]const u8, env_len + extra_len);
    var i: usize = 0;
    if (env) |v| {
        for (v) |item| {
            out[i] = item;
            i += 1;
        }
    }
    if (extra) |v| {
        for (v) |item| {
            out[i] = item;
            i += 1;
        }
    }
    return out;
}

fn appendEnvExport(list: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return;
    if (eq == 0) return;
    const key = line[0..eq];
    if (!isValidEnvKey(key)) return;
    const value = line[eq + 1 ..];

    const escaped = try escapeForShell(allocator, value);
    defer allocator.free(escaped);

    try list.appendSlice(allocator, "export ");
    try list.appendSlice(allocator, key);
    try list.appendSlice(allocator, "=");
    try list.appendSlice(allocator, escaped);
    try list.appendSlice(allocator, "; ");
}

fn isValidEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const first = key[0];
    if (!((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_')) return false;
    for (key[1..]) |ch| {
        if (!((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_')) return false;
    }
    return true;
}

/// Perform the actual detach action.
pub fn performDetach(state: *State) void {
    // Always set detach_mode to prevent killing panes on exit.
    state.detach_mode = true;

    // Serialize entire mux state.
    const mux_state_json = state.serializeState() catch {
        state.notifications.showFor("Failed to serialize state", 2000);
        state.running = false;
        return;
    };
    defer state.allocator.free(mux_state_json);

    // Detach session with our UUID - panes stay grouped with full state.
    state.ses_client.detachSession(state.uuid, mux_state_json) catch {
        std.debug.print("\nDetach failed - panes orphaned\n", .{});
        state.running = false;
        return;
    };
    // Print session_id (our UUID) so user can reattach.
    std.debug.print("\nSession detached: {s}\nReattach with: hexe-mux --attach {s}\n", .{ state.uuid, state.uuid[0..8] });
    state.running = false;
}

/// Perform the actual disown action - orphan pane in ses and spawn new shell in same place.
pub fn performDisown(state: *State) void {
    const pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (pane) |p| {
        switch (p.backend) {
            .pod => {
                // Get current working directory from the process before orphaning.
                const cwd = state.getSpawnCwd(p);

                // Get the old pane's auxiliary info (created_from, focused_from) to inherit.
                const old_aux = state.ses_client.getPaneAux(p.uuid) catch SesClient.PaneAuxInfo{
                    .created_from = null,
                    .focused_from = null,
                };

                // Orphan the current pane in ses (keeps process alive).
                state.ses_client.orphanPane(p.uuid) catch {};

                // Create a new shell via ses in the same directory and replace the pane's backend.
                if (state.ses_client.createPane(null, cwd, null, null, null, null)) |result| {
                    const vt_fd = state.ses_client.getVtFd() orelse {
                        state.notifications.show("Disown failed: no VT channel");
                        state.needs_render = true;
                        return;
                    };
                    p.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch {
                        state.notifications.show("Disown failed: couldn't replace pane");
                        state.needs_render = true;
                        return;
                    };

                    // Sync inherited auxiliary info to the new pane.
                    const pane_type: SesClient.PaneType = if (p.floating) .float else .split;
                    const cursor = p.getCursorPos();
                    const cursor_style = p.vt.getCursorStyle();
                    const cursor_visible = p.vt.isCursorVisible();
                    const alt_screen = p.vt.inAltScreen();
                    const layout_path = helpers.getLayoutPath(state, p) catch null;
                    defer if (layout_path) |path| state.allocator.free(path);
                    state.ses_client.updatePaneAux(
                        p.uuid,
                        p.floating,
                        p.focused,
                        pane_type,
                        old_aux.created_from, // Inherit creator.
                        old_aux.focused_from, // Inherit last focus.
                        .{ .x = cursor.x, .y = cursor.y },
                        cursor_style,
                        cursor_visible,
                        alt_screen,
                        .{ .cols = p.width, .rows = p.height },
                        cwd,
                        null,
                        null,
                        layout_path,
                    ) catch {};

                    state.notifications.show("Pane disowned (adopt with Alt+a)");
                } else |_| {
                    state.notifications.show("Disown failed: couldn't create new pane");
                }
            },
            .local => {
                // Local process - just respawn.
                p.respawn() catch {
                    state.notifications.show("Respawn failed");
                    state.needs_render = true;
                    return;
                };
                state.notifications.show("Pane respawned");
            },
        }
    }
    state.needs_render = true;
}

/// Perform the actual close action - close current float or tab.
pub fn performClose(state: *State) void {
    if (state.active_floating) |idx| {
        const old_uuid = state.getCurrentFocusedUuid();
        const pane = state.floats.orderedRemove(idx);
        state.syncPaneUnfocus(pane);
        float_completion.handleBlockingFloatCompletion(state, pane);
        // Kill in ses.
        if (state.ses_client.isConnected()) {
            state.ses_client.killPane(pane.uuid) catch {};
        }
        pane.deinit();
        state.allocator.destroy(pane);
        // Focus another float or fall back to tiled pane.
        if (state.floats.items.len > 0) {
            state.active_floating = 0;
            state.syncPaneFocus(state.floats.items[0], old_uuid);
        } else {
            state.active_floating = null;
            if (state.currentLayout().getFocusedPane()) |tiled| {
                state.syncPaneFocus(tiled, old_uuid);
            }
        }
        state.syncStateToSes();
    } else {
        // Close current tab, or quit if it's the last one.
        if (!state.closeCurrentTab()) {
            state.running = false;
        }
    }
    state.needs_render = true;
}

/// Start the adopt orphaned pane flow.
pub fn startAdoptFlow(state: *State) void {
    if (!state.ses_client.isConnected()) {
        state.notifications.show("Not connected to ses");
        return;
    }

    // Get list of orphaned panes.
    const count = state.ses_client.listOrphanedPanes(&state.adopt_orphans) catch {
        state.notifications.show("Failed to list orphaned panes");
        return;
    };

    if (count == 0) {
        state.notifications.show("No orphaned panes");
        return;
    }

    state.adopt_orphan_count = count;

    if (count == 1) {
        // Only one orphan - skip picker, go directly to confirm.
        state.adopt_selected_uuid = state.adopt_orphans[0].uuid;
        state.pending_action = .adopt_confirm;
        state.popups.showConfirm("Destroy current pane?", .{}) catch {};
    } else {
        // Multiple orphans - show picker.
        // Build items list for picker (owned by popup).
        var items_list: std.ArrayList([]const u8) = .empty;
        defer items_list.deinit(state.allocator);
        for (0..count) |i| {
            items_list.append(state.allocator, state.adopt_orphans[i].uuid[0..]) catch {
                state.notifications.show("Failed to show picker");
                return;
            };
        }
        state.pending_action = .adopt_choose;
        state.popups.showPickerOwned(items_list.items, .{ .title = "Select pane to adopt" }) catch {
            state.notifications.show("Failed to show picker");
            state.pending_action = null;
        };
    }
    state.needs_render = true;
}

/// Perform the actual adopt action.
/// If destroy_current is true, kills the current pane; otherwise orphans it (swap).
pub fn performAdopt(state: *State, orphan_uuid: [32]u8, destroy_current: bool) void {
    // Adopt the selected orphan from ses.
    const result = state.ses_client.adoptPane(orphan_uuid) catch {
        state.notifications.show("Failed to adopt pane");
        return;
    };

    // Get the current focused pane.
    const current_pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (current_pane) |pane| {
        if (destroy_current) {
            // Kill current pane in ses, then replace with adopted.
            state.ses_client.killPane(pane.uuid) catch {};
        } else {
            // Orphan current pane (swap mode).
            state.ses_client.orphanPane(pane.uuid) catch {};
            state.notifications.show("Swapped panes (old pane orphaned)");
        }

        const vt_fd = state.ses_client.getVtFd() orelse {
            state.notifications.show("Failed to replace pane: no VT channel");
            return;
        };

        pane.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch {
            state.notifications.show("Failed to replace pane");
            return;
        };

        // Sync the new pane info.
        state.syncPaneAux(pane, null);
        state.syncStateToSes();

        if (destroy_current) {
            state.notifications.show("Adopted pane (old destroyed)");
        }
    } else {
        state.notifications.show("No focused pane");
    }

    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

pub fn toggleNamedFloat(state: *State, float_def: *const core.FloatDef) void {
    // Get current directory from focused pane (for pwd floats).
    // Use refreshPaneCwd which queries ses for pod panes.
    var current_dir: ?[]const u8 = null;
    if (state.currentLayout().getFocusedPane()) |focused| {
        current_dir = state.refreshPaneCwd(focused);
    }

    // Find existing float by key (and directory if pwd).
    for (state.floats.items, 0..) |pane, i| {
        if (pane.float_key == float_def.key) {
            // Tab-bound: skip if on wrong tab.
            if (pane.parent_tab) |parent| {
                if (parent != state.active_tab) continue;
            }

            // For pwd floats, also check directory match.
            if (float_def.attributes.per_cwd and pane.is_pwd) {
                // Both dirs must exist and match, or both be null.
                const dirs_match = if (pane.pwd_dir) |pane_dir| blk: {
                    if (current_dir) |curr| {
                        break :blk std.mem.eql(u8, pane_dir, curr);
                    }
                    break :blk false;
                } else current_dir == null;

                if (!dirs_match) continue;
            }

            // Toggle visibility (per-tab for global floats).
            const old_uuid = state.getCurrentFocusedUuid();
            pane.toggleVisibleOnTab(state.active_tab);
            if (pane.isVisibleOnTab(state.active_tab)) {
                // Unfocus current pane (tiled or another float).
                if (state.active_floating) |afi| {
                    if (afi < state.floats.items.len) {
                        state.syncPaneUnfocus(state.floats.items[afi]);
                    }
                } else if (state.currentLayout().getFocusedPane()) |tiled| {
                    state.syncPaneUnfocus(tiled);
                }
                state.active_floating = i;
                state.syncPaneFocus(pane, old_uuid);
                // If alone mode, hide all other floats on this tab.
                if (float_def.attributes.exclusive) {
                    for (state.floats.items) |other| {
                        if (other.float_key != float_def.key) {
                            other.setVisibleOnTab(state.active_tab, false);
                        }
                    }
                }
            } else {
                // Float was hidden. If it had focus, return focus to tiled pane.
                if (state.active_floating == i) {
                    state.syncPaneUnfocus(pane);
                    state.active_floating = null;
                    if (state.currentLayout().getFocusedPane()) |tiled| {
                        state.syncPaneFocus(tiled, old_uuid);
                    }
                }
            }

            state.renderer.invalidate();
            state.force_full_render = true;
            state.needs_render = true;
            return;
        }
    }

    // No existing float - create new.
    const old_uuid = state.getCurrentFocusedUuid();
    if (state.active_floating) |afi| {
        if (afi < state.floats.items.len) {
            state.syncPaneUnfocus(state.floats.items[afi]);
        }
    } else if (state.currentLayout().getFocusedPane()) |tiled| {
        state.syncPaneUnfocus(tiled);
    }

    createNamedFloat(state, float_def, current_dir, old_uuid) catch {
        state.notifications.show("Failed to create float");
        state.needs_render = true;
        return;
    };

    // If alone mode, hide all other floats on this tab.
    if (float_def.attributes.exclusive) {
        for (state.floats.items) |pane| {
            if (pane.float_key != float_def.key) {
                pane.setVisibleOnTab(state.active_tab, false);
            }
        }
    }
    // For pwd floats, hide other instances of same float (different dirs) on this tab.
    if (float_def.attributes.per_cwd) {
        const new_idx = state.floats.items.len - 1;
        for (state.floats.items, 0..) |pane, i| {
            if (i != new_idx and pane.float_key == float_def.key) {
                pane.setVisibleOnTab(state.active_tab, false);
            }
        }
    }
}

pub fn createAdhocFloat(
    state: *State,
    command: []const u8,
    title: ?[]const u8,
    cwd: ?[]const u8,
    env: ?[]const []const u8,
    extra_env: ?[]const []const u8,
    use_pod: bool,
) ![32]u8 {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;
    const style = if (cfg.float_style_default) |*s| s else null;
    const shadow_enabled = if (style) |s| s.shadow_color != null else false;
    const width_pct: u16 = cfg.float_width_percent;
    const height_pct: u16 = cfg.float_height_percent;
    const pos_x_pct: u16 = 50;
    const pos_y_pct: u16 = 50;
    const pad_x_cfg: u16 = cfg.float_padding_x;
    const pad_y_cfg: u16 = cfg.float_padding_y;
    const border_color = cfg.float_color;

    const avail_h = state.term_height - state.status_height;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;
    const outer_w = usable_w * width_pct / 100;
    const outer_h = usable_h * height_pct / 100;
    const max_x = usable_w -| outer_w;
    const max_y = usable_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.floats.items.len);

    if (use_pod and state.ses_client.isConnected()) {
        if (state.ses_client.createPane(command, cwd, null, null, env, extra_env)) |result| {
            if (state.ses_client.getVtFd()) |vt_fd| {
                try pane.initWithPod(state.allocator, id, content_x, content_y, content_w, content_h, result.pane_id, vt_fd, result.uuid);
            } else {
                const merged_env = mergeEnvLines(state.allocator, env, extra_env) catch null;
                defer if (merged_env) |slice| state.allocator.free(slice);
                try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, command, cwd, merged_env);
            }
        } else |_| {
            const merged_env = mergeEnvLines(state.allocator, env, extra_env) catch null;
            defer if (merged_env) |slice| state.allocator.free(slice);
            try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, command, cwd, merged_env);
        }
    } else {
        const merged_env = mergeEnvLines(state.allocator, env, extra_env) catch null;
        defer if (merged_env) |slice| state.allocator.free(slice);
        try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, command, cwd, merged_env);
    }

    pane.floating = true;
    pane.focused = true;
    pane.float_key = 0;
    pane.visible = true;

    if (title) |t| {
        if (t.len > 0) {
            pane.float_title = try state.allocator.dupe(u8, t);
        }
    }

    if (state.ses_client.isConnected()) {
        state.ses_client.updatePaneName(pane.uuid, pane.float_title) catch {};
    }

    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;

    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    pane.parent_tab = state.active_tab;
    pane.sticky = false;

    if (style) |s| {
        pane.float_style = s;
    }

    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.floats.append(state.allocator, pane);
    state.active_floating = state.floats.items.len - 1;
    state.syncPaneAux(pane, null);
    state.syncStateToSes();

    return pane.uuid;
}

pub fn createNamedFloat(state: *State, float_def: *const core.FloatDef, current_dir: ?[]const u8, parent_uuid: ?[32]u8) !void {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;

    const style = if (float_def.style) |*s| s else if (cfg.float_style_default) |*s| s else null;
    const shadow_enabled = if (style) |s| s.shadow_color != null else false;

    // Use per-float settings or fall back to defaults.
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50; // default center
    const pos_y_pct: u16 = float_def.pos_y orelse 50; // default center
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color = float_def.color orelse cfg.float_color;

    // Calculate outer frame size.
    const avail_h = state.term_height - state.status_height;
    const usable_w: u16 = if (shadow_enabled) (state.term_width -| 1) else state.term_width;
    const usable_h: u16 = if (shadow_enabled and state.status_height == 0) (avail_h -| 1) else avail_h;
    const outer_w = usable_w * width_pct / 100;
    const outer_h = usable_h * height_pct / 100;

    // Calculate position based on pos_x/pos_y percentages.
    const max_x = usable_w -| outer_w;
    const max_y = usable_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Content area: 1 cell border + configurable padding.
    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.floats.items.len);

    const isolate_env = [_][]const u8{"HEXE_POD_ISOLATE=1"};
    const extra_env: ?[]const []const u8 = if (float_def.attributes.isolated) &isolate_env else null;

    // Try to create pane via ses if available.
    if (state.ses_client.isConnected()) {
        if (state.ses_client.createPane(float_def.command, current_dir, null, null, null, extra_env)) |result| {
            if (state.ses_client.getVtFd()) |vt_fd| {
                try pane.initWithPod(state.allocator, id, content_x, content_y, content_w, content_h, result.pane_id, vt_fd, result.uuid);
            } else {
                try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command, current_dir, extra_env);
            }
        } else |_| {
            // Fall back to local spawn.
            try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command, current_dir, extra_env);
        }
    } else {
        try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command, current_dir, extra_env);
    }

    pane.floating = true;
    pane.focused = true;
    pane.float_key = float_def.key;

    // Title text is a pane property (outside style). Style only controls
    // positioning/formatting of the title widget.
    if (float_def.title) |t| {
        if (t.len > 0) {
            pane.float_title = state.allocator.dupe(u8, t) catch null;
        }
    }

    if (state.ses_client.isConnected()) {
        state.ses_client.updatePaneName(pane.uuid, pane.float_title) catch {};
    }
    // For global floats (special or pwd), set per-tab visibility.
    // For tab-bound floats, use simple visible field.
    if (float_def.attributes.global or float_def.attributes.per_cwd) {
        pane.setVisibleOnTab(state.active_tab, true);
    } else {
        pane.visible = true;
    }
    // Store outer dimensions and style for border rendering.
    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;
    // Store percentages for resize recalculation.
    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    // For pwd floats, store the directory and duplicate it.
    if (float_def.attributes.per_cwd) {
        pane.is_pwd = true;
        if (current_dir) |dir| {
            pane.pwd_dir = state.allocator.dupe(u8, dir) catch null;
        }
    }

    // For tab-bound floats, set parent tab.
    if (!float_def.attributes.global and !float_def.attributes.per_cwd) {
        pane.parent_tab = state.active_tab;
    }

    // For sticky floats, set sticky.
    pane.sticky = float_def.attributes.sticky;

    // Store style reference.
    if (style) |s| {
        pane.float_style = s;
    }

    // Configure pane notifications.
    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.floats.append(state.allocator, pane);
    state.active_floating = state.floats.items.len - 1;
    state.syncPaneAux(pane, parent_uuid);
    state.syncStateToSes();
}

const pop = @import("pop");

/// Enter pane select mode - displays numbered labels on all panes.
/// If swap is true, selecting a pane will swap it with the focused pane.
/// If swap is false, selecting a pane will just focus it.
pub fn enterPaneSelectMode(state: *State, swap: bool) void {
    state.overlays.enterPaneSelectMode(swap);

    // Generate labels for all visible panes
    var label_idx: usize = 0;

    // Add split panes from current layout
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

    // Add visible floats
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
    // Check floats first
    for (state.floats.items, 0..) |pane, i| {
        if (std.mem.eql(u8, &pane.uuid, &uuid)) {
            if (!pane.isVisibleOnTab(state.active_tab)) continue;
            if (pane.parent_tab) |parent| {
                if (parent != state.active_tab) continue;
            }

            // Unfocus current
            state.unfocusAllPanes();

            // Focus this float
            state.active_floating = i;
            pane.focused = true;
            state.syncPaneFocus(pane, null);
            state.needs_render = true;
            return;
        }
    }

    // Check split panes in current layout
    const layout = state.currentLayout();
    var it = layout.splits.iterator();
    while (it.next()) |entry| {
        const pane = entry.value_ptr.*;
        if (std.mem.eql(u8, &pane.uuid, &uuid)) {
            // Unfocus current
            state.unfocusAllPanes();

            // Focus this split pane
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

    // ESC cancels
    if (byte == 0x1b) {
        state.overlays.exitPaneSelectMode();
        state.needs_render = true;
        return true;
    }

    // Uppercase = swap, lowercase = focus
    const is_swap = byte >= 'A' and byte <= 'Z';
    const label: u8 = if (is_swap) byte + 32 else byte;

    // Only handle a-z
    if (label < 'a' or label > 'z') return true;

    if (state.overlays.findPaneByLabel(label)) |target_uuid| {
        if (is_swap) {
            // Swap: exchange positions of focused pane and target pane
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

    // Invalid label - ignore but consume
    return true;
}

/// Get the currently focused pane (float or split).
fn getCurrentFocusedPane(state: *State) ?*Pane {
    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) return state.floats.items[idx];
    }
    return state.currentLayout().getFocusedPane();
}

/// Swap the screen positions of two panes.
/// VTs, backends, and UUIDs stay with their pane objects — only the
/// position in the layout / float array changes so each pane renders
/// where the other one used to be.
fn swapPanePositions(state: *State, pane_a: *Pane, pane_b: *Pane) void {
    if (pane_a == pane_b) return;

    const a_float = pane_a.floating;
    const b_float = pane_b.floating;

    if (!a_float and !b_float) {
        // Both are split panes — swap pointers in the layout hashmap.
        const layout = state.currentLayout();

        var key_a: ?u16 = null;
        var key_b: ?u16 = null;
        var it = layout.splits.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == pane_a) key_a = entry.key_ptr.*;
            if (entry.value_ptr.* == pane_b) key_b = entry.key_ptr.*;
        }
        if (key_a == null or key_b == null) return;

        // Swap *Pane values in the hashmap
        layout.splits.putAssumeCapacity(key_a.?, pane_b);
        layout.splits.putAssumeCapacity(key_b.?, pane_a);

        // Swap pane IDs so each pane.id matches its new hashmap key
        const tmp_id = pane_a.id;
        pane_a.id = pane_b.id;
        pane_b.id = tmp_id;

        // Keep focus on the same pane (follow it to its new slot)
        if (layout.focused_split_id == key_a.?) {
            layout.focused_split_id = key_b.?;
        } else if (layout.focused_split_id == key_b.?) {
            layout.focused_split_id = key_a.?;
        }

        // Recalculate — assigns new x/y/w/h and resizes VTs + backends
        layout.recalculateLayout();
    } else if (a_float and b_float) {
        // Both are floats — swap their position/border fields, then resize.
        swapFloatPositions(pane_a, pane_b);
    } else {
        // Mixed split + float — not supported yet
        state.notifications.show("Cannot swap split with float");
        return;
    }

    state.renderer.invalidate();
    state.force_full_render = true;
    state.needs_render = true;
}

/// Swap position and border fields between two float panes, then resize VTs.
fn swapFloatPositions(a: *Pane, b: *Pane) void {
    // Content area
    const ax = a.x;     const ay = a.y;
    const aw = a.width;  const ah = a.height;
    a.x = b.x;           a.y = b.y;
    a.width = b.width;   a.height = b.height;
    b.x = ax;            b.y = ay;
    b.width = aw;        b.height = ah;

    // Border area
    const abx = a.border_x; const aby = a.border_y;
    const abw = a.border_w; const abh = a.border_h;
    a.border_x = b.border_x; a.border_y = b.border_y;
    a.border_w = b.border_w; a.border_h = b.border_h;
    b.border_x = abx; b.border_y = aby;
    b.border_w = abw; b.border_h = abh;

    // Layout percentages
    const awp = a.float_width_pct;  const ahp = a.float_height_pct;
    const axp = a.float_pos_x_pct;  const ayp = a.float_pos_y_pct;
    const apx = a.float_pad_x;      const apy = a.float_pad_y;
    a.float_width_pct = b.float_width_pct;   a.float_height_pct = b.float_height_pct;
    a.float_pos_x_pct = b.float_pos_x_pct;   a.float_pos_y_pct = b.float_pos_y_pct;
    a.float_pad_x = b.float_pad_x;            a.float_pad_y = b.float_pad_y;
    b.float_width_pct = awp;  b.float_height_pct = ahp;
    b.float_pos_x_pct = axp;  b.float_pos_y_pct = ayp;
    b.float_pad_x = apx;      b.float_pad_y = apy;

    // Resize VTs to their new dimensions
    a.vt.resize(a.width, a.height) catch {};
    b.vt.resize(b.width, b.height) catch {};

    // Resize backends
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
