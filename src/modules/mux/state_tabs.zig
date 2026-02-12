const std = @import("std");
const core = @import("core");
const mux = @import("main.zig");

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

/// Find a pane by its SES-assigned pane_id (pod panes only).
pub fn findPaneByPaneId(self: anytype, pane_id: u16) ?*Pane {
    for (self.floats.items) |pane| {
        if (pane.getPaneId()) |id| {
            if (id == pane_id) return pane;
        }
    }

    for (self.tabs.items) |*tab| {
        var it = tab.layout.splits.valueIterator();
        while (it.next()) |p| {
            if (p.*.getPaneId()) |id| {
                if (id == pane_id) return p.*;
            }
        }
    }

    return null;
}

/// Create a new tab with one pane.
pub fn createTab(self: anytype) !void {
    const parent_uuid = self.getCurrentFocusedUuid();

    // Get cwd from currently focused pane (float or split), with fallback to mux's cwd.
    var cwd: ?[]const u8 = null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (self.tabs.items.len > 0) {
        // Check active float first, then split pane
        const focused_pane: ?*Pane = if (self.active_floating) |idx| blk: {
            if (idx < self.floats.items.len) break :blk self.floats.items[idx];
            break :blk null;
        } else self.currentLayout().getFocusedPane();

        if (focused_pane) |focused| {
            // Use getReliableCwd which tries multiple sources
            cwd = self.getReliableCwd(focused);
        }
        // If pane CWD is null, fall back to mux's current directory
        if (cwd == null) {
            cwd = std.posix.getcwd(&cwd_buf) catch null;
        }
    } else {
        // First tab - use mux's current directory.
        cwd = std.posix.getcwd(&cwd_buf) catch null;
    }

    // Generate tab name in format "session-N" (e.g., "alpha-1", "beta-2")
    const name_owned = try core.ipc.generateTabName(self.allocator, self.session_name, self.tab_counter);

    // Increment tab counter with overflow protection.
    // If counter approaches maximum, wrap to 0 to prevent corruption.
    if (self.tab_counter < 999) {
        self.tab_counter += 1;
    } else {
        mux.debugLog("VALIDATION: tab_counter reached limit, wrapping to 0", .{});
        self.tab_counter = 0;
    }
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
                self.ses_client.killPane(fp.uuid) catch |e| {
                    core.logging.logError("mux", "killPane failed in closeTab", e);
                };
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
    for (self.active_layout_floats) |*float_def| {
        if (!float_def.attributes.sticky) continue;

        // Try to find a sticky pane in ses matching this directory + key.
        const result = self.ses_client.findStickyPane(cwd, float_def.key) catch continue;
        if (result) |r| {
            // Found a sticky pane - adopt it as a float.
            self.adoptAsFloat(r.uuid, r.pane_id, float_def, cwd) catch continue;
            self.notifications.showFor("Sticky float restored", 2000);
        }
    }
}

/// Adopt a pane from ses as a float with given float definition.
pub fn adoptAsFloat(self: anytype, uuid: [32]u8, pane_id: u16, float_def: *const core.LayoutFloatDef, cwd: []const u8) !void {
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

    // Initialize pane with the adopted pod — VT routed through SES.
    const vt_fd = self.ses_client.getVtFd() orelse return error.NoVtChannel;
    try pane.initWithPod(self.allocator, id, content_x, content_y, content_w, content_h, pane_id, vt_fd, uuid);

    // Request pane info to populate pane name (Pokemon name) for sprites
    std.debug.print("[DEBUG] About to request pane info, ctl_fd={}\n", .{self.ses_client.ctl_fd != null});
    if (self.ses_client.ctl_fd) |ctl_fd| {
        const msg = core.wire.PaneUuid{ .uuid = uuid };
        std.debug.print("[DEBUG] Sending pane_info request for uuid\n", .{});
        core.wire.writeControl(ctl_fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
            std.debug.print("[DEBUG] Failed to send pane_info: {}\n", .{err});
        };
    } else {
        std.debug.print("[DEBUG] ctl_fd is null, cannot request pane info!\n", .{});
    }

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
    const vt_fd = self.ses_client.getVtFd() orelse return false;

    // Get the current focused pane and replace it.
    if (self.active_floating) |idx| {
        const old_pane = self.floats.items[idx];
        old_pane.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch return false;
    } else if (self.currentLayout().getFocusedPane()) |pane| {
        pane.replaceWithPod(result.pane_id, vt_fd, result.uuid) catch return false;
    } else {
        return false;
    }

    self.renderer.invalidate();
    self.force_full_render = true;
    return true;
}

/// Validate the structure of mux state JSON before attempting restoration.
/// This prevents crashes from malformed/corrupted JSON.
fn validateMuxStateJson(value: *const std.json.Value) bool {
    // Root must be an object
    if (value.* != .object) {
        mux.debugLog("validateMuxStateJson: root is not an object", .{});
        return false;
    }
    const root = value.object;

    // Required fields with type checks
    const required_fields = .{
        .{ "uuid", .string },
        .{ "session_name", .string },
        .{ "tab_counter", .integer },
        .{ "tabs", .array },
        .{ "floats", .array },
        .{ "active_tab", .integer },
    };

    inline for (required_fields) |field_spec| {
        const field_name = field_spec[0];
        const expected_type = field_spec[1];

        const field_value = root.get(field_name) orelse {
            mux.debugLog("validateMuxStateJson: missing required field '{s}'", .{field_name});
            return false;
        };

        const matches = switch (expected_type) {
            .string => field_value == .string,
            .integer => field_value == .integer,
            .array => field_value == .array,
            else => false,
        };

        if (!matches) {
            mux.debugLog("validateMuxStateJson: field '{s}' has wrong type", .{field_name});
            return false;
        }
    }

    // active_floating can be null or integer
    if (root.get("active_floating")) |af| {
        if (af != .null and af != .integer) {
            mux.debugLog("validateMuxStateJson: active_floating must be null or integer", .{});
            return false;
        }
    }

    // Validate tabs array elements
    const tabs = root.get("tabs").?.array;
    for (tabs.items) |tab_val| {
        if (tab_val != .object) {
            mux.debugLog("validateMuxStateJson: tabs array contains non-object", .{});
            return false;
        }
        const tab_obj = tab_val.object;

        // Each tab must have name, splits array
        if (tab_obj.get("name")) |name| {
            if (name != .string) {
                mux.debugLog("validateMuxStateJson: tab name is not a string", .{});
                return false;
            }
        } else {
            mux.debugLog("validateMuxStateJson: tab missing name", .{});
            return false;
        }

        if (tab_obj.get("splits")) |splits| {
            if (splits != .array) {
                mux.debugLog("validateMuxStateJson: tab splits is not an array", .{});
                return false;
            }
        }
    }

    // Validate floats array elements
    const floats = root.get("floats").?.array;
    for (floats.items) |float_val| {
        if (float_val != .object) {
            mux.debugLog("validateMuxStateJson: floats array contains non-object", .{});
            return false;
        }
    }

    mux.debugLog("validateMuxStateJson: validation passed", .{});
    return true;
}

/// Reattach to a detached session, restoring full state.
pub fn reattachSession(self: anytype, session_id_prefix: []const u8) bool {
    mux.debugLog("reattachSession: starting with prefix={s}", .{session_id_prefix});
    std.debug.print("[mux] REATTACH: starting for prefix={s}\n", .{session_id_prefix});

    // Set flag to prevent SIGHUP from interrupting reattach
    self.reattach_in_progress.store(true, .release);
    defer self.reattach_in_progress.store(false, .release);

    // Track reattach start time for timeout detection
    const reattach_start = std.time.milliTimestamp();

    if (!self.ses_client.isConnected()) {
        mux.debugLog("reattachSession: ses_client not connected, aborting", .{});
        std.debug.print("[mux] REATTACH: ses_client not connected, aborting\n", .{});
        return false;
    }

    // Try to reattach session (server supports prefix matching).
    mux.debugLog("reattachSession: calling ses_client.reattachSession", .{});
    std.debug.print("[mux] REATTACH: calling ses_client.reattachSession\n", .{});
    const result = self.ses_client.reattachSession(session_id_prefix) catch |e| {
        mux.debugLog("reattachSession: ses_client.reattachSession failed: {s}", .{@errorName(e)});
        std.debug.print("[mux] REATTACH: ses_client.reattachSession FAILED: {s}\n", .{@errorName(e)});
        return false;
    };
    if (result == null) {
        mux.debugLog("reattachSession: ses_client.reattachSession returned null (session not found)", .{});
        std.debug.print("[mux] REATTACH: ses_client returned null (not found)\n", .{});
        return false;
    }

    const reattach_result = result.?;
    mux.debugLog("reattachSession: got result with {d} panes, state_json_len={d}", .{ reattach_result.pane_uuids.len, reattach_result.mux_state_json.len });
    std.debug.print("[mux] REATTACH: got result with {d} panes, json_len={d}\n", .{ reattach_result.pane_uuids.len, reattach_result.mux_state_json.len });
    defer {
        self.allocator.free(reattach_result.mux_state_json);
        self.allocator.free(reattach_result.pane_uuids);
    }

    // Parse the mux state JSON.
    std.debug.print("[mux] REATTACH: parsing JSON...\n", .{});
    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reattach_result.mux_state_json, .{}) catch |e| {
        mux.debugLog("reattachSession: JSON parse failed: {s}", .{@errorName(e)});
        std.debug.print("[mux] REATTACH: JSON parse FAILED: {s}\n", .{@errorName(e)});
        return false;
    };
    defer parsed.deinit();

    std.debug.print("[mux] REATTACH: JSON parsed OK\n", .{});

    // Validate JSON schema before attempting to use it
    if (!validateMuxStateJson(&parsed.value)) {
        mux.debugLog("reattachSession: JSON schema validation failed", .{});
        std.debug.print("[mux] REATTACH: JSON schema INVALID\n", .{});
        return false;
    }
    std.debug.print("[mux] REATTACH: JSON schema valid\n", .{});

    // Validate serialization version and checksum for integrity
    if (parsed.value.object.get("version")) |ver_val| {
        if (ver_val == .integer) {
            const version: u32 = @intCast(ver_val.integer);
            if (version > 1) {
                mux.debugLog("reattachSession: unsupported version {d}, current is 1", .{version});
                self.notifications.showFor("Warning: Session data from newer version, may be incompatible", 5000);
            }
        }
    }

    // Verify checksum if present
    if (parsed.value.object.get("_checksum")) |checksum_val| {
        if (checksum_val == .integer) {
            const stored_checksum: u64 = @intCast(checksum_val.integer);
            // Recalculate checksum on content before the checksum field
            // Find where ",\"_checksum\":" starts in the JSON
            const json_str = reattach_result.mux_state_json;
            if (std.mem.lastIndexOf(u8, json_str, ",\"_checksum\":")) |checksum_pos| {
                const content_only = json_str[0..checksum_pos];
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(content_only);
                hasher.update("}"); // Add the closing brace that was part of original
                const calculated_checksum = hasher.final();

                if (calculated_checksum != stored_checksum) {
                    mux.debugLog("reattachSession: checksum mismatch! stored={d} calculated={d}", .{ stored_checksum, calculated_checksum });
                    self.notifications.showFor("Warning: Session data integrity check failed (corrupted?)", 5000);
                    // Continue anyway but user is warned
                }
            }
        }
    }

    // Check timeout after JSON parsing
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after JSON parse ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: JSON parsing took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed)",
                .{@divTrunc(elapsed, 1000)},
            ) catch "Warning: reattach taking longer than expected";
            defer if (msg.ptr != "Warning: reattach taking longer than expected".ptr) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after JSON parse ({d}ms)", .{elapsed});
        }
    }

    const root = parsed.value.object;

    // Clear current UI state before restoring.
    //
    // If we leave the previous session's tabs/panes around and then append the
    // restored tabs, focus and routing can point at panes that were never
    // adopted (blank/frozen) or double-adopted.
    // This is especially important for `hexe mux attach` because the mux starts
    // by creating a fresh tab, then reattaches.
    {
        // Deinit existing tab state.
        while (self.tabs.items.len > 0) {
            const tab_opt = self.tabs.pop();
            if (tab_opt) |tab_const| {
                var tab = tab_const;
                tab.deinit();
            }
        }

        // Deinit any existing floats.
        while (self.floats.items.len > 0) {
            const p_opt = self.floats.pop();
            if (p_opt) |p| {
                p.deinit();
                self.allocator.destroy(p);
            }
        }

        self.active_tab = 0;
        self.active_floating = null;
        self.tab_last_floating_uuid.clearRetainingCapacity();
        self.tab_last_focus_kind.clearRetainingCapacity();
    }

    // Restore mux UUID (persistent identity).
    if (root.get("uuid")) |uuid_val| {
        const uuid_str = uuid_val.string;
        if (uuid_str.len == 32) {
            @memcpy(&self.uuid, uuid_str[0..32]);
        }
    }

    // Restore session name (must dupe since parsed JSON will be freed).
    if (root.get("session_name")) |name_val| {
        var restored_name = name_val.string;

        // VALIDATION: Detect and fix corrupted session_name.
        // Session names should be Greek letters (alpha, beta, ...) optionally with
        // collision suffix "-2", "-3", etc. They should NEVER be tab names like "alpha-1".
        // Tab names have format "session-N" where N starts at 1.
        //
        // If the restored name looks like a tab name (ends with "-1", "-2", etc.),
        // strip the suffix to recover the actual session name.
        //
        // Heuristic: If name ends with "-N" where N is a single digit >= 1,
        // it's likely a corrupted tab name. Strip the suffix.
        if (restored_name.len >= 3) {
            const last_char = restored_name[restored_name.len - 1];
            if (last_char >= '1' and last_char <= '9') {
                // Check if there's a dash before the digit.
                if (restored_name[restored_name.len - 2] == '-') {
                    // This looks like "alpha-1" format (tab name).
                    // Strip the "-N" suffix to recover session name.
                    restored_name = restored_name[0 .. restored_name.len - 2];
                    mux.debugLog("VALIDATION: stripped corrupted tab-format suffix from session_name, recovered: {s}", .{restored_name});
                    std.debug.print("[mux] REATTACH: session_name was corrupted (tab format), recovered: {s}\n", .{restored_name});
                }
            }
        }

        // Free previous owned name if any.
        if (self.session_name_owned) |old| {
            self.allocator.free(old);
        }
        // Dupe the validated name from JSON.
        const duped = self.allocator.dupe(u8, restored_name) catch return false;
        self.session_name = duped;
        self.session_name_owned = duped;
    }

    // Restore tab counter (for session-N tab naming).
    if (root.get("tab_counter")) |tc_val| {
        if (tc_val == .integer) {
            const restored_counter: usize = @intCast(tc_val.integer);
            // Validate tab_counter is reasonable (not absurdly large).
            // A counter > 1000 suggests corruption or overflow.
            if (restored_counter > 1000) {
                mux.debugLog("VALIDATION: tab_counter suspiciously large ({d}), resetting to 0", .{restored_counter});
                self.tab_counter = 0;
            } else {
                self.tab_counter = restored_counter;
            }
        } else {
            mux.debugLog("VALIDATION: tab_counter is not an integer type, defaulting to 0", .{});
            self.tab_counter = 0;
        }
    }

    // Remember active tab/floating from the stored state.
    // We apply these after restoring tabs/floats so indices are valid.
    const wanted_active_tab: usize = if (root.get("active_tab")) |at| blk: {
        if (at != .integer) {
            mux.debugLog("reattachSession: active_tab is not an integer, defaulting to 0", .{});
            break :blk 0;
        }
        break :blk @intCast(at.integer);
    } else 0;
    const wanted_active_floating: ?usize = if (root.get("active_floating")) |af| blk: {
        if (af == .null) break :blk null;
        if (af != .integer) {
            mux.debugLog("reattachSession: active_floating is not an integer, defaulting to null", .{});
            break :blk null;
        }
        break :blk @intCast(af.integer);
    } else null;

    // Build a map of UUID -> pane_id for adopted panes.
    const AdoptInfo = struct { pane_id: u16 };
    var uuid_pane_map = std.AutoHashMap([32]u8, AdoptInfo).init(self.allocator);
    defer uuid_pane_map.deinit();

    // Track which UUIDs have been used during restoration to detect duplicates in JSON.
    var used_uuids = std.AutoHashMap([32]u8, void).init(self.allocator);
    defer used_uuids.deinit();

    mux.debugLog("reattachSession: adopting {d} panes", .{reattach_result.pane_uuids.len});
    std.debug.print("[mux] REATTACH: adopting {d} panes\n", .{reattach_result.pane_uuids.len});
    // Track adoption failures for user notification
    var failed_adoptions: usize = 0;
    const total_panes = reattach_result.pane_uuids.len;

    for (reattach_result.pane_uuids, 0..) |uuid, i| {
        mux.debugLog("reattachSession: adopting pane {d}/{d} uuid={s}", .{ i + 1, total_panes, uuid[0..8] });
        std.debug.print("[mux] REATTACH: adoptPane {d}/{d} uuid={s}\n", .{ i + 1, total_panes, uuid[0..8] });

        // Check for duplicate UUID in the list
        if (uuid_pane_map.contains(uuid)) {
            mux.debugLog("reattachSession: DUPLICATE UUID detected: {s}, skipping", .{uuid[0..8]});
            std.debug.print("[mux] REATTACH: DUPLICATE UUID {s}, skipping\n", .{uuid[0..8]});
            failed_adoptions += 1;
            continue;
        }

        const adopt_result = self.ses_client.adoptPane(uuid) catch |e| {
            mux.debugLog("reattachSession: adoptPane failed for uuid={s}: {s}", .{ uuid[0..8], @errorName(e) });
            std.debug.print("[mux] REATTACH: adoptPane FAILED: {s}\n", .{@errorName(e)});
            failed_adoptions += 1;
            continue;
        };
        mux.debugLog("reattachSession: adoptPane success, pane_id={d}", .{adopt_result.pane_id});
        std.debug.print("[mux] REATTACH: adoptPane OK pane_id={d}\n", .{adopt_result.pane_id});
        uuid_pane_map.put(uuid, .{ .pane_id = adopt_result.pane_id }) catch {
            failed_adoptions += 1;
            continue;
        };
    }
    mux.debugLog("reattachSession: adopted {d} panes into uuid_pane_map", .{uuid_pane_map.count()});
    std.debug.print("[mux] REATTACH: adopted {d} panes total\n", .{uuid_pane_map.count()});

    // Notify user if some panes failed to reattach
    if (failed_adoptions > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d}/{d} panes failed to reattach",
            .{ failed_adoptions, total_panes },
        ) catch "Warning: Some panes failed to reattach";
        defer if (msg.ptr != "Warning: Some panes failed to reattach".ptr) self.allocator.free(msg);
        self.notifications.showFor(msg, 5000);
        mux.debugLog("reattachSession: notified user about {d} failed adoptions", .{failed_adoptions});
    }

    // Check timeout after pane adoption
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after pane adoption ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: pane adoption took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s elapsed, {d} panes adopted)",
                .{ @divTrunc(elapsed, 1000), uuid_pane_map.count() },
            ) catch "Warning: reattach taking longer than expected";
            defer if (msg.ptr != "Warning: reattach taking longer than expected".ptr) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after adoption ({d}ms)", .{elapsed});
        }
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

                    // Check for duplicate UUID - if already used, skip this pane.
                    if (used_uuids.contains(uuid_arr)) {
                        mux.debugLog("reattachSession: duplicate UUID in splits: {s}, skipping", .{uuid_arr[0..8]});
                        continue;
                    }

                    // Try adopting from pre-collected pane_uuids first,
                    // then try adopting directly from SES by UUID.
                    var adopt_info: ?AdoptInfo = uuid_pane_map.get(uuid_arr);
                    if (adopt_info == null) {
                        // pane_uuids was empty — try adopting directly from SES.
                        if (self.ses_client.adoptPane(uuid_arr)) |adopt_res| {
                            adopt_info = .{ .pane_id = adopt_res.pane_id };
                        } else |_| {}
                    }

                    const info = adopt_info orelse continue;

                    // Mark this UUID as used.
                    used_uuids.put(uuid_arr, {}) catch {};
                    const pane = self.allocator.create(Pane) catch continue;
                    const vt_fd = self.ses_client.getVtFd() orelse {
                        self.allocator.destroy(pane);
                        continue;
                    };

                    pane.initWithPod(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, uuid_arr) catch {
                        self.allocator.destroy(pane);
                        continue;
                    };

                    // Request pane info to populate pane name
                    std.debug.print("[DEBUG] About to request pane info (restore panes), ctl_fd={}\n", .{self.ses_client.ctl_fd != null});
                    if (self.ses_client.ctl_fd) |ctl_fd| {
                        const msg = core.wire.PaneUuid{ .uuid = uuid_arr };
                        std.debug.print("[DEBUG] Sending pane_info request for uuid\n", .{});
                        core.wire.writeControl(ctl_fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
                            std.debug.print("[DEBUG] Failed to send pane_info: {}\n", .{err});
                        };
                    } else {
                        std.debug.print("[DEBUG] ctl_fd is null!\n", .{});
                    }

                    // Restore pane properties.
                    pane.focused = if (pane_obj.get("focused")) |f| (f == .bool and f.bool) else false;

                    tab.layout.splits.put(pane_id, pane) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        continue;
                    };
                }
            }

            // Restore layout tree.
            if (tab_obj.get("tree")) |tree_val| {
                if (tree_val != .null) {
                    tab.layout.root = self.deserializeLayoutNode(tree_val.object) catch null;
                }
            }

            self.tabs.append(self.allocator, tab) catch {
                // Clean up tab and all its panes on append failure
                tab.deinit();
                continue;
            };
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

            // Check for duplicate UUID - if already used, skip this float.
            if (used_uuids.contains(uuid_arr)) {
                mux.debugLog("reattachSession: duplicate UUID in floats: {s}, skipping", .{uuid_arr[0..8]});
                continue;
            }

            {
                // Try adopting from pre-collected pane_uuids first,
                // then try adopting directly from SES by UUID.
                var adopt_info: ?AdoptInfo = uuid_pane_map.get(uuid_arr);
                if (adopt_info == null) {
                    if (self.ses_client.adoptPane(uuid_arr)) |adopt_res| {
                        adopt_info = .{ .pane_id = adopt_res.pane_id };
                    } else |_| {}
                }

                const info = adopt_info orelse continue;

                // Mark this UUID as used.
                used_uuids.put(uuid_arr, {}) catch {};
                const pane = self.allocator.create(Pane) catch continue;
                const vt_fd = self.ses_client.getVtFd() orelse {
                    self.allocator.destroy(pane);
                    continue;
                };

                pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, info.pane_id, vt_fd, uuid_arr) catch {
                    self.allocator.destroy(pane);
                    continue;
                };

                // Request pane info to populate pane name
                if (self.ses_client.ctl_fd) |ctl_fd| {
                    const msg = core.wire.PaneUuid{ .uuid = uuid_arr };
                    core.wire.writeControl(ctl_fd, .pane_info, std.mem.asBytes(&msg)) catch {};
                }

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
                pane.parent_tab = if (pane_obj.get("parent_tab")) |pt| blk: {
                    if (pt != .integer) {
                        mux.debugLog("reattachSession: parent_tab is not an integer for float pane", .{});
                        break :blk null;
                    }
                    const parent_idx: usize = @intCast(pt.integer);
                    // Validate against tabs count (will be validated again after all tabs restored)
                    break :blk parent_idx;
                } else null;

                // Re-apply float style and border color from config definition.
                // These are config pointers that can't be serialized, so we look
                // up the FloatDef by the restored float_key.
                if (pane.float_key != 0) {
                    if (self.getLayoutFloatByKey(pane.float_key)) |float_def| {
                        const style = if (float_def.style) |*s| s else if (self.config.float_style_default) |*s| s else null;
                        if (style) |s| {
                            pane.float_style = s;
                        }
                        pane.border_color = float_def.color orelse self.config.float_color;
                    }
                }

                // Restore pwd_dir for per_cwd floats.
                if (pane_obj.get("pwd_dir")) |pwd_val| {
                    if (pwd_val == .string) {
                        pane.pwd_dir = self.allocator.dupe(u8, pwd_val.string) catch null;
                    }
                }

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


    // Prune dead pane nodes from layout trees. Pods that died during detach
    // (e.g., from SIGPIPE) leave orphan nodes in the tree that would corrupt
    // the layout by allocating space for non-existent panes.
    for (self.tabs.items) |*tab| {
        tab.layout.pruneDeadNodes();
    }

    // Remove tabs that have no live panes (all pods died).
    {
        var i: usize = 0;
        var removed_tabs: usize = 0;
        while (i < self.tabs.items.len) {
            if (self.tabs.items[i].layout.splits.count() == 0) {
                // Don't remove the LAST tab - keep at least one tab always.
                if (self.tabs.items.len > 1) {
                    const tab_name = self.tabs.items[i].name;
                    mux.debugLog("reattachSession: removing empty tab: {s}", .{tab_name});
                    var dead_tab = self.tabs.orderedRemove(i);
                    dead_tab.deinit();
                    removed_tabs += 1;
                    // Don't increment i, next tab shifted into this position
                } else {
                    mux.debugLog("reattachSession: keeping last empty tab to prevent zero tabs", .{});
                    i += 1;
                }
            } else {
                i += 1;
            }
        }

        // Notify user if tabs were removed
        if (removed_tabs > 0) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: {d} empty tab(s) removed (all panes died)",
                .{removed_tabs},
            ) catch "Warning: Empty tabs were removed";
            defer if (msg.ptr != "Warning: Empty tabs were removed".ptr) self.allocator.free(msg);
            self.notifications.showFor(msg, 4000);
            mux.debugLog("reattachSession: removed {d} empty tabs", .{removed_tabs});
        }
    }

    // Safety check: ensure we have at least one tab.
    // If all tabs were empty and removed, create a new one.
    if (self.tabs.items.len == 0) {
        mux.debugLog("reattachSession: CRITICAL - all tabs removed, creating new tab", .{});
        self.createTab() catch {
            mux.debugLog("reattachSession: FAILED to create recovery tab", .{});
            return false;
        };
        self.notifications.showFor("Warning: All tabs were empty, created new tab", 5000);
    }

    // Recalculate all layouts for current terminal size.
    for (self.tabs.items) |*tab| {
        tab.layout.resize(self.layout_width, self.layout_height);
    }

    // Validate and fix parent_tab indices for floating panes
    var invalid_parent_tabs: usize = 0;
    for (self.floats.items) |fp| {
        if (fp.parent_tab) |parent_idx| {
            if (parent_idx >= self.tabs.items.len) {
                mux.debugLog("reattachSession: invalid parent_tab {d} (only {d} tabs), setting to null", .{ parent_idx, self.tabs.items.len });
                fp.parent_tab = null;
                invalid_parent_tabs += 1;
            }
        }
    }
    // Notify user if any parent_tab links were broken
    if (invalid_parent_tabs > 0) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Warning: {d} float(s) had invalid parent tab, reset to global",
            .{invalid_parent_tabs},
        ) catch "Warning: Some floats had invalid parent tab references";
        defer if (msg.ptr != "Warning: Some floats had invalid parent tab references".ptr) self.allocator.free(msg);
        self.notifications.showFor(msg, 4000);
        mux.debugLog("reattachSession: corrected {d} invalid parent_tab references", .{invalid_parent_tabs});
    }

    // Recalculate floating pane positions.
    self.resizeFloatingPanes();

    // Apply restored active indices now that all state is present.
    if (self.tabs.items.len > 0) {
        self.active_tab = @min(wanted_active_tab, self.tabs.items.len - 1);
    } else {
        self.active_tab = 0;
    }
    self.active_floating = if (wanted_active_floating) |idx|
        if (idx < self.floats.items.len) idx else null
    else
        null;

    self.renderer.invalidate();
    self.force_full_render = true;

    std.debug.print("[mux] REATTACH: tabs restored={d}, floats restored={d}\n", .{ self.tabs.items.len, self.floats.items.len });

    // Check timeout after layout restoration
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after layout restore ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: layout restoration took too long", 5000);
            return false;
        } else if (elapsed > 10000) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Warning: reattach slow ({d}s total, {d} tabs restored)",
                .{ @divTrunc(elapsed, 1000), self.tabs.items.len },
            ) catch "Warning: reattach taking longer than expected";
            defer if (msg.ptr != "Warning: reattach taking longer than expected".ptr) self.allocator.free(msg);
            self.notifications.showFor(msg, 3000);
            mux.debugLog("reattachSession: slow progress warning after layout restore ({d}ms)", .{elapsed});
        }
    }

    // Signal SES that we're ready for backlog replay.
    // This triggers deferred VT reconnection to PODs, which replays their buffers.
    std.debug.print("[mux] REATTACH: calling requestBacklogReplay\n", .{});
    self.ses_client.requestBacklogReplay() catch |e| {
        std.debug.print("[mux] REATTACH: requestBacklogReplay FAILED: {s}\n", .{@errorName(e)});
    };
    std.debug.print("[mux] REATTACH: requestBacklogReplay done\n", .{});

    // Final timeout check after backlog replay
    {
        const elapsed = std.time.milliTimestamp() - reattach_start;
        mux.debugLog("reattachSession: total elapsed time: {d}ms", .{elapsed});
        if (elapsed > 30000) {
            mux.debugLog("reattachSession: timeout after backlog replay ({d}ms > 30s), aborting", .{elapsed});
            self.notifications.showFor("Reattach timeout: session restored but backlog replay incomplete", 5000);
            // Don't return false here - the session is already restored, just warn user
        }
    }

    if (self.tabs.items.len == 0) {
        std.debug.print("[mux] REATTACH: no tabs restored, returning false\n", .{});
        return false;
    }

    // Restore succeeded — re-register with SES using restored UUID/name.
    // This also removes the detached session from SES (via handleBinaryRegister).
    std.debug.print("[mux] REATTACH: calling updateSession uuid={s} name={s}\n", .{ self.uuid[0..8], self.session_name });
    self.ses_client.updateSession(self.uuid, self.session_name) catch |e| {
        core.logging.logError("mux", "updateSession failed in restoreLayout", e);
        std.debug.print("[mux] REATTACH: updateSession FAILED: {s}\n", .{@errorName(e)});
    };

    std.debug.print("[mux] REATTACH: returning true, tabs={d} floats={d}\n", .{ self.tabs.items.len, self.floats.items.len });
    return true;
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
            var tab_needs_cleanup = true;
            defer if (tab_needs_cleanup) tab.deinit();

            if (self.ses_client.isConnected()) {
                tab.layout.setSesClient(&self.ses_client);
            }
            tab.layout.setPanePopConfig(&self.pop_config.pane.notification);

            const vt_fd = self.ses_client.getVtFd() orelse return false;

            const pane = self.allocator.create(Pane) catch return false;
            var pane_needs_cleanup = true;
            defer if (pane_needs_cleanup) self.allocator.destroy(pane);

            pane.initWithPod(self.allocator, 0, 0, 0, self.layout_width, self.layout_height, result.pane_id, vt_fd, result.uuid) catch {
                return false;
            };

            // Request pane info to populate pane name
            std.debug.print("[DEBUG] About to request pane info (adopt), ctl_fd={}\n", .{self.ses_client.ctl_fd != null});
            if (self.ses_client.ctl_fd) |ctl_fd| {
                const msg = core.wire.PaneUuid{ .uuid = result.uuid };
                std.debug.print("[DEBUG] Sending pane_info request for uuid\n", .{});
                core.wire.writeControl(ctl_fd, .pane_info, std.mem.asBytes(&msg)) catch |err| {
                    std.debug.print("[DEBUG] Failed to send pane_info: {}\n", .{err});
                };
            } else {
                std.debug.print("[DEBUG] ctl_fd is null!\n", .{});
            }

            pane.focused = true;
            pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

            // Add pane to layout manually.
            tab.layout.splits.put(0, pane) catch {
                pane.deinit();
                return false;
            };
            // Pane is now owned by tab, no longer needs separate cleanup
            pane_needs_cleanup = false;

            const node = self.allocator.create(LayoutNode) catch return false;
            node.* = .{ .pane = 0 };
            tab.layout.root = node;
            tab.layout.next_split_id = 1;

            self.tabs.append(self.allocator, tab) catch return false;
            // Tab is now owned by tabs array, no longer needs cleanup
            tab_needs_cleanup = false;
            self.active_tab = self.tabs.items.len - 1;
            self.renderer.invalidate();
            self.force_full_render = true;
            return true;
        }
    }
    return false;
}
