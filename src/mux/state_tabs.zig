const std = @import("std");
const core = @import("core");

const state_types = @import("state_types.zig");
const Tab = state_types.Tab;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;

const Pane = @import("pane.zig").Pane;
const ses_client = @import("ses_client.zig");
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;

/// Get the current tab's layout.
pub fn currentLayout(self: anytype) *Layout {
    return &self.tabs.items[self.active_tab].layout;
}

pub fn findPaneByUuid(self: anytype, uuid: [32]u8) ?*Pane {
    for (self.floats.items) |pane| {
        if (std.mem.eql(u8, &pane.uuid, &uuid)) return pane;
    }

    for (self.tabs.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |p| {
            if (std.mem.eql(u8, &p.*.uuid, &uuid)) return p.*;
        }
    }

    return null;
}

/// Create a new tab with one pane.
pub fn createTab(self: anytype) !void {
    const parent_uuid = self.getCurrentFocusedUuid();

    // Get cwd from currently focused pane, or use mux's cwd for first tab.
    var cwd: ?[]const u8 = null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (self.tabs.items.len > 0) {
        if (self.currentLayout().getFocusedPane()) |focused| {
            // Refresh CWD from ses for pod panes.
            cwd = self.refreshPaneCwd(focused);
        }
    } else {
        // First tab - use mux's current directory.
        cwd = std.posix.getcwd(&cwd_buf) catch null;
    }

    const base_name = core.ipc.generateTabName();
    const name_owned = try self.allocator.dupe(u8, base_name);
    var tab = Tab.initOwned(self.allocator, self.layout_width, self.layout_height, name_owned, self.pop_config.carrier.notification);
    // Set ses client if connected (for new tabs after startup).
    if (self.ses_client.isConnected()) {
        tab.layout.setSesClient(&self.ses_client);
    }
    // Set pane notification config.
    tab.layout.setPanePopConfig(&self.pop_config.pane.notification);
    const first_pane = try tab.layout.createFirstPane(cwd);
    try self.tabs.append(self.allocator, tab);
    // Keep per-tab float focus state in sync.
    try self.tab_last_floating_uuid.append(self.allocator, null);
    try self.tab_last_focus_kind.append(self.allocator, .split);
    self.active_tab = self.tabs.items.len - 1;
    self.syncPaneAux(first_pane, parent_uuid);
    self.renderer.invalidate();
    self.force_full_render = true;
    self.syncStateToSes();
}

/// Close the current tab.
pub fn closeCurrentTab(self: anytype) bool {
    if (self.tabs.items.len <= 1) return false;
    const closing_tab = self.active_tab;

    // Handle tab-bound floats belonging to this tab.
    var i: usize = 0;
    while (i < self.floats.items.len) {
        const fp = self.floats.items[i];
        if (fp.parent_tab) |parent| {
            if (parent == closing_tab) {
                // Kill this tab-bound float.
                self.ses_client.killPane(fp.uuid) catch {};
                fp.deinit();
                self.allocator.destroy(fp);
                _ = self.floats.orderedRemove(i);
                // Clear active_floating if it was this float.
                if (self.active_floating) |afi| {
                    if (afi == i) {
                        self.active_floating = null;
                    } else if (afi > i) {
                        self.active_floating = afi - 1;
                    }
                }
                continue;
            } else if (parent > closing_tab) {
                // Adjust index for floats on later tabs.
                fp.parent_tab = parent - 1;
            }
        }
        i += 1;
    }

    var tab = self.tabs.orderedRemove(self.active_tab);
    tab.deinit();
    _ = self.tab_last_floating_uuid.orderedRemove(self.active_tab);
    _ = self.tab_last_focus_kind.orderedRemove(self.active_tab);
    if (self.active_tab >= self.tabs.items.len) {
        self.active_tab = self.tabs.items.len - 1;
    }
    self.renderer.invalidate();
    self.force_full_render = true;
    self.syncStateToSes();
    return true;
}

/// Adopt sticky panes from ses on startup.
/// Finds sticky panes matching current directory and configured sticky floats.
pub fn adoptStickyPanes(self: anytype) void {
    if (!self.ses_client.isConnected()) return;

    // Get current working directory.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return;

    // Check each float definition for sticky floats.
    for (self.config.floats) |*float_def| {
        if (!float_def.attributes.sticky) continue;

        // Try to find a sticky pane in ses matching this directory + key.
        const result = self.ses_client.findStickyPane(cwd, float_def.key) catch continue;
        if (result) |r| {
            // Found a sticky pane - adopt it as a float.
            defer self.allocator.free(r.socket_path);
            self.adoptAsFloat(r.uuid, r.socket_path, r.pid, float_def, cwd) catch continue;
            self.notifications.showFor("Sticky float restored", 2000);
        }
    }
}

/// Adopt a pane from ses as a float with given float definition.
pub fn adoptAsFloat(self: anytype, uuid: [32]u8, socket_path: []const u8, pid: std.posix.pid_t, float_def: *const core.FloatDef, cwd: []const u8) !void {
    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);

    const cfg = &self.config;

    // Use per-float settings or fall back to defaults.
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50;
    const pos_y_pct: u16 = float_def.pos_y orelse 50;
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color = float_def.color orelse cfg.float_color;

    // Calculate outer frame size.
    const avail_h = self.term_height - self.status_height;
    const outer_w = self.term_width * width_pct / 100;
    const outer_h = avail_h * height_pct / 100;

    // Calculate position based on percentage.
    const max_x = if (self.term_width > outer_w) self.term_width - outer_w else 0;
    const max_y = if (avail_h > outer_h) avail_h - outer_h else 0;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Apply padding.
    const pad_x: u16 = @intCast(@min(pad_x_cfg, outer_w / 4));
    const pad_y: u16 = @intCast(@min(pad_y_cfg, outer_h / 4));
    const content_x = outer_x + 1 + pad_x;
    const content_y = outer_y + 1 + pad_y;
    const content_w = if (outer_w > 2 + 2 * pad_x) outer_w - 2 - 2 * pad_x else 1;
    const content_h = if (outer_h > 2 + 2 * pad_y) outer_h - 2 - 2 * pad_y else 1;

    // Generate pane ID (floats use 100+ offset).
    const id: u16 = @intCast(100 + self.floats.items.len);

    _ = pid;
    // Initialize pane with the adopted pod.
    try pane.initWithPod(self.allocator, id, content_x, content_y, content_w, content_h, socket_path, uuid);

    pane.floating = true;
    pane.focused = true;
    pane.float_key = float_def.key;
    pane.sticky = float_def.attributes.sticky;

    // For global floats (special or pwd), set per-tab visibility.
    if (float_def.attributes.global or float_def.attributes.per_cwd) {
        pane.setVisibleOnTab(self.active_tab, true);
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

    // Store pwd for pwd floats.
    if (float_def.attributes.per_cwd) {
        pane.is_pwd = true;
        pane.pwd_dir = self.allocator.dupe(u8, cwd) catch null;
    }

    // For tab-bound floats, set parent tab.
    if (!float_def.attributes.global and !float_def.attributes.per_cwd) {
        pane.parent_tab = self.active_tab;
    }

    // Store style reference.
    if (float_def.style) |*style| {
        pane.float_style = style;
    }

    // Configure pane notifications.
    pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

    try self.floats.append(self.allocator, pane);
    // Don't set active_floating here - let user toggle it manually.
}

/// Switch to next tab.
pub fn nextTab(self: anytype) void {
    if (self.tabs.items.len > 1) {
        self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
        self.renderer.invalidate();
        self.force_full_render = true;
    }
}

/// Switch to previous tab.
pub fn prevTab(self: anytype) void {
    if (self.tabs.items.len > 1) {
        self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
        self.renderer.invalidate();
        self.force_full_render = true;
    }
}

/// Adopt first orphaned pane, replacing current focused pane.
pub fn adoptOrphanedPane(self: anytype) bool {
    if (!self.ses_client.isConnected()) return false;

    // Get list of orphaned panes.
    var panes: [32]OrphanedPaneInfo = undefined;
    const count = self.ses_client.listOrphanedPanes(&panes) catch return false;
    if (count == 0) return false;

    // Adopt the first one.
    const result = self.ses_client.adoptPane(panes[0].uuid) catch return false;
    defer self.allocator.free(result.socket_path);

    // Get the current focused pane and replace it.
    if (self.active_floating) |idx| {
        const old_pane = self.floats.items[idx];
        old_pane.replaceWithPod(result.socket_path, result.uuid) catch return false;
    } else if (self.currentLayout().getFocusedPane()) |pane| {
        pane.replaceWithPod(result.socket_path, result.uuid) catch return false;
    } else {
        return false;
    }

    self.renderer.invalidate();
    self.force_full_render = true;
    return true;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    if (!self.ses_client.isConnected()) return false;

    // Try to reattach session (server supports prefix matching).
    const result = self.ses_client.reattachSession(session_id_prefix) catch return false;
    if (result == null) return false;

    const reattach_result = result.?;
    defer {
        self.allocator.free(reattach_result.mux_state_json);
        self.allocator.free(reattach_result.pane_uuids);
    }

    // Parse the mux state JSON.
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reattach_result.mux_state_json, .{}) catch return false;
    defer parsed.deinit();

    const root = parsed.value.object;

    // Restore mux UUID (persistent identity).
    if (root.get("uuid")) |uuid_val| {
        const uuid_str = uuid_val.string;
        if (uuid_str.len == 32) {
            @memcpy(&self.uuid, uuid_str[0..32]);
        }
    }

    // Restore session name (must dupe since parsed JSON will be freed).
    if (root.get("session_name")) |name_val| {
        // Free previous owned name if any.
        if (self.session_name_owned) |old| {
            self.allocator.free(old);
        }
        // Dupe the name from JSON.
        const duped = self.allocator.dupe(u8, name_val.string) catch return false;
        self.session_name = duped;
        self.session_name_owned = duped;
    }

    // Re-register with ses using restored UUID and session_name.
    self.ses_client.updateSession(self.uuid, self.session_name) catch {};

    // Restore active tab/floating.
    if (root.get("active_tab")) |at| {
        self.active_tab = @intCast(at.integer);
    }
    if (root.get("active_floating")) |af| {
        self.active_floating = if (af == .null) null else @intCast(af.integer);
    }

    // Build a map of UUID -> pod socket path for pane adoption.
    var uuid_socket_map = std.AutoHashMap([32]u8, []u8).init(self.allocator);
    defer {
        var vit = uuid_socket_map.valueIterator();
        while (vit.next()) |sock| {
            self.allocator.free(sock.*);
        }
        uuid_socket_map.deinit();
    }

    for (reattach_result.pane_uuids) |uuid| {
        const adopt_result = self.ses_client.adoptPane(uuid) catch continue;
        uuid_socket_map.put(uuid, adopt_result.socket_path) catch {
            self.allocator.free(adopt_result.socket_path);
            continue;
        };
    }

    // Restore tabs.
    if (root.get("tabs")) |tabs_arr| {
        for (tabs_arr.array.items) |tab_val| {
            const tab_obj = tab_val.object;
            const name_json = (tab_obj.get("name") orelse continue).string;
            const focused_split_id: u16 = @intCast((tab_obj.get("focused_split_id") orelse continue).integer);
            const next_split_id: u16 = @intCast((tab_obj.get("next_split_id") orelse continue).integer);

            // Dupe the name since parsed JSON will be freed.
            const name_owned = self.allocator.dupe(u8, name_json) catch continue;
            var tab = Tab.initOwned(self.allocator, self.layout_width, self.layout_height, name_owned, self.pop_config.carrier.notification);

            // Restore tab UUID if present.
            if (tab_obj.get("uuid")) |uuid_val| {
                const uuid_str = uuid_val.string;
                if (uuid_str.len == 32) {
                    @memcpy(&tab.uuid, uuid_str[0..32]);
                }
            }

            if (self.ses_client.isConnected()) {
                tab.layout.setSesClient(&self.ses_client);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);
            tab.layout.focused_split_id = focused_split_id;
            tab.layout.next_split_id = next_split_id;

            // Restore splits.
            if (tab_obj.get("splits")) |splits_arr| {
                for (splits_arr.array.items) |pane_val| {
                    const pane_obj = pane_val.object;
                    const pane_id: u16 = @intCast((pane_obj.get("id") orelse continue).integer);
                    const uuid_str = (pane_obj.get("uuid") orelse continue).string;
                    if (uuid_str.len != 32) continue;

                    // Convert to [32]u8 for lookup.
                    var uuid_arr: [32]u8 = undefined;
                    @memcpy(&uuid_arr, uuid_str[0..32]);

                    if (uuid_socket_map.get(uuid_arr)) |sock| {
                        const pane = self.allocator.create(Pane) catch continue;

                        pane.initWithPod(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, sock, uuid_arr) catch {
                            self.allocator.destroy(pane);
                            continue;
                        };

                        // Restore pane properties.
                        pane.focused = if (pane_obj.get("focused")) |f| (f == .bool and f.bool) else false;

                        tab.layout.splits.put(pane_id, pane) catch {
                            pane.deinit();
                            self.allocator.destroy(pane);
                            continue;
                        };
                    }
                }
            }

            // Restore layout tree.
            if (tab_obj.get("tree")) |tree_val| {
                if (tree_val != .null) {
                    tab.layout.root = self.deserializeLayoutNode(tree_val.object) catch null;
                }
            }

            self.tabs.append(self.allocator, tab) catch continue;
        }
    }

    // Reset per-tab float focus tracking to match restored tabs.
    self.tab_last_floating_uuid.clearRetainingCapacity();
    self.tab_last_floating_uuid.ensureTotalCapacity(self.allocator, self.tabs.items.len) catch {};
    for (0..self.tabs.items.len) |_| {
        self.tab_last_floating_uuid.appendAssumeCapacity(null);
    }

    self.tab_last_focus_kind.clearRetainingCapacity();
    self.tab_last_focus_kind.ensureTotalCapacity(self.allocator, self.tabs.items.len) catch {};
    for (0..self.tabs.items.len) |_| {
        self.tab_last_focus_kind.appendAssumeCapacity(.split);
    }

    // Restore floats.
    if (root.get("floats")) |floats_arr| {
        for (floats_arr.array.items) |pane_val| {
            const pane_obj = pane_val.object;
            const uuid_str = (pane_obj.get("uuid") orelse continue).string;
            if (uuid_str.len != 32) continue;

            var uuid_arr: [32]u8 = undefined;
            @memcpy(&uuid_arr, uuid_str[0..32]);

            if (uuid_socket_map.get(uuid_arr)) |sock| {
                const pane = self.allocator.create(Pane) catch continue;

                pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, sock, uuid_arr) catch {
                    self.allocator.destroy(pane);
                    continue;
                };

                // Restore float properties.
                pane.floating = true;
                pane.visible = if (pane_obj.get("visible")) |v| (v != .bool or v.bool) else true;
                pane.tab_visible = if (pane_obj.get("tab_visible")) |tv| @intCast(tv.integer) else 0;
                pane.float_key = if (pane_obj.get("float_key")) |fk| @intCast(fk.integer) else 0;
                pane.float_width_pct = if (pane_obj.get("float_width_pct")) |wp| @intCast(wp.integer) else 60;
                pane.float_height_pct = if (pane_obj.get("float_height_pct")) |hp| @intCast(hp.integer) else 60;
                pane.float_pos_x_pct = if (pane_obj.get("float_pos_x_pct")) |xp| @intCast(xp.integer) else 50;
                pane.float_pos_y_pct = if (pane_obj.get("float_pos_y_pct")) |yp| @intCast(yp.integer) else 50;
                pane.float_pad_x = if (pane_obj.get("float_pad_x")) |px| @intCast(px.integer) else 1;
                pane.float_pad_y = if (pane_obj.get("float_pad_y")) |py| @intCast(py.integer) else 0;
                pane.is_pwd = if (pane_obj.get("is_pwd")) |ip| (ip == .bool and ip.bool) else false;
                pane.sticky = if (pane_obj.get("sticky")) |s| (s == .bool and s.bool) else false;
                pane.parent_tab = if (pane_obj.get("parent_tab")) |pt|
                    @intCast(pt.integer)
                else
                    null;

                // Configure pane notifications.
                pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

                // Restore float title from ses memory (best-effort).
                if (self.ses_client.isConnected()) {
                    if (self.ses_client.getPaneName(uuid_arr)) |name| {
                        pane.float_title = name;
                    }
                }

                self.floats.append(self.allocator, pane) catch {
                    pane.deinit();
                    self.allocator.destroy(pane);
                    continue;
                };
            }
        }
    }

    // Recalculate all layouts for current terminal size.
    for (self.tabs.items) |*tab| {
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    // Recalculate floating pane positions.
    self.resizeFloatingPanes();

    self.renderer.invalidate();
    self.force_full_render = true;
    return self.tabs.items.len > 0;
}

/// Attach to orphaned pane by UUID prefix (for --attach CLI).
pub fn attachOrphanedPane(self: anytype, uuid_prefix: []const u8) bool {
    if (!self.ses_client.isConnected()) return false;

    // Get list of orphaned panes and find matching UUID.
    var tabs: [32]OrphanedPaneInfo = undefined;
    const count = self.ses_client.listOrphanedPanes(&tabs) catch return false;

    for (tabs[0..count]) |p| {
        if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
            // Found matching pane, adopt it.
            const result = self.ses_client.adoptPane(p.uuid) catch return false;

            // Create a new tab with this pane.
            var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, "attached", self.pop_config.carrier.notification);
            if (self.ses_client.isConnected()) {
                tab.layout.setSesClient(&self.ses_client);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

            defer self.allocator.free(result.socket_path);

            const pane = self.allocator.create(Pane) catch return false;
            pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.socket_path, result.uuid) catch {
                self.allocator.destroy(pane);
                return false;
            };
            pane.focused = true;
            pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

            // Add pane to layout manually.
            tab.layout.splits.put(0, pane) catch {
                pane.deinit();
                self.allocator.destroy(pane);
                return false;
            };
            const node = self.allocator.create(LayoutNode) catch return false;
            node.* = .{ .pane = 0 };
            tab.layout.root = node;
            tab.layout.next_split_id = 1;

            self.tabs.append(self.allocator, tab) catch return false;
            self.active_tab = self.tabs.items.len - 1;
            self.renderer.invalidate();
            self.force_full_render = true;
            return true;
        }
    }
    return false;
}
