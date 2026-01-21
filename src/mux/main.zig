const std = @import("std");
const posix = std.posix;
const core = @import("core");
const shp = @import("shp");
const statusbar = @import("statusbar.zig");
const popup_render = @import("popup_render.zig");
const pop = @import("pop");
const input = @import("input.zig");
const borders = @import("borders.zig");
const terminal = @import("terminal.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const Pane = @import("pane.zig").Pane;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const LayoutNode = layout_mod.LayoutNode;
const SplitDir = @import("layout.zig").SplitDir;
const render = @import("render.zig");
const Renderer = render.Renderer;
const ses_client = @import("ses_client.zig");
const SesClient = ses_client.SesClient;
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;
const notification = @import("notification.zig");
const NotificationManager = notification.NotificationManager;

var debug_enabled: bool = false;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    std.debug.print("[mux] " ++ fmt ++ "\n", args);
}

/// Pending action that needs confirmation
const PendingAction = enum {
    exit,
    detach,
    disown,
    close,
    adopt_choose, // Choosing which orphaned pane to adopt
    adopt_confirm, // Confirming destroy vs swap
};

/// A tab contains a layout with splits (splits)
const Tab = struct {
    layout: Layout,
    name: []const u8,
    uuid: [32]u8,
    notifications: NotificationManager,
    popups: pop.PopupManager,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16, name: []const u8, notif_cfg: pop.NotificationStyle) Tab {
        return .{
            .layout = Layout.init(allocator, width, height),
            .name = name,
            .uuid = core.ipc.generateUuid(),
            .notifications = NotificationManager.initWithPopConfig(allocator, notif_cfg),
            .popups = pop.PopupManager.init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Tab) void {
        self.layout.deinit();
        self.notifications.deinit();
        self.popups.deinit();
    }
};

const PendingFloatRequest = struct {
    fd: posix.fd_t,
    result_path: ?[]u8,
};

const State = struct {
    allocator: std.mem.Allocator,
    config: core.Config,
    pop_config: pop.PopConfig,
    tabs: std.ArrayList(Tab),
    active_tab: usize,
    floats: std.ArrayList(*Pane),
    active_floating: ?usize,
    running: bool,
    detach_mode: bool,
    needs_render: bool,
    force_full_render: bool,
    term_width: u16,
    term_height: u16,
    status_height: u16,
    layout_width: u16,
    layout_height: u16,
    renderer: Renderer,
    ses_client: SesClient,
    notifications: NotificationManager,
    popups: pop.PopupManager, // For blocking popups (confirm, choose)
    pending_action: ?PendingAction, // Action waiting for confirmation (exit/detach)
    exit_from_shell_death: bool, // True if exit confirmation was triggered by shell death
    // Adopt flow state
    adopt_orphans: [32]OrphanedPaneInfo = undefined, // Cached orphaned panes for picker
    adopt_orphan_count: usize = 0, // Number of orphaned panes
    adopt_selected_uuid: ?[32]u8 = null, // Selected orphan UUID after picker
    skip_dead_check: bool, // Skip dead pane processing this iteration (after respawn)
    pending_pop_response: bool, // True if waiting to send pop response
    pending_pop_scope: pop.Scope, // Which scope the pending popup belongs to
    pending_pop_tab: usize, // Tab index if scope is .tab
    pending_pop_pane: ?*Pane, // Pane pointer if scope is .pane
    uuid: [32]u8,
    session_name: []const u8,
    session_name_owned: ?[]const u8, // If set, points to owned memory that must be freed
    ipc_server: ?core.ipc.Server,
    socket_path: ?[]const u8,

    // OSC query proxy (for color queries)
    osc_reply_target_uuid: ?[32]u8,
    osc_reply_buf: std.ArrayList(u8),
    osc_reply_in_progress: bool,
    osc_reply_prev_esc: bool,

    pending_float_requests: std.AutoHashMap([32]u8, PendingFloatRequest),

    fn init(allocator: std.mem.Allocator, width: u16, height: u16, debug: bool, log_file: ?[]const u8) !State {
        const cfg = core.Config.load(allocator);
        const pop_cfg = pop.PopConfig.load(allocator);
        const status_h: u16 = if (cfg.tabs.status.enabled) 1 else 0;
        const layout_h = height - status_h;

        // Generate UUID and session name for this mux instance
        const uuid = core.ipc.generateUuid();
        const session_name = core.ipc.generateSessionName();

        // Create IPC server socket
        const socket_path = core.ipc.getMuxSocketPath(allocator, &uuid) catch null;
        var ipc_server: ?core.ipc.Server = null;
        if (socket_path) |path| {
            ipc_server = core.ipc.Server.init(allocator, path) catch null;
        }

        return .{
            .allocator = allocator,
            .config = cfg,
            .pop_config = pop_cfg,
            .tabs = .empty,
            .active_tab = 0,
            .floats = .empty,
            .active_floating = null,
            .running = true,
            .detach_mode = false,
            .needs_render = true,
            .force_full_render = true,
            .term_width = width,
            .term_height = height,
            .status_height = status_h,
            .layout_width = width,
            .layout_height = layout_h,
            .renderer = try Renderer.init(allocator, width, height),
            .ses_client = SesClient.init(allocator, uuid, session_name, true, debug, log_file), // keepalive=true by default
            .notifications = NotificationManager.initWithPopConfig(allocator, pop_cfg.carrier.notification),
            .popups = pop.PopupManager.init(allocator),
            .pending_action = null,
            .exit_from_shell_death = false,
            .skip_dead_check = false,
            .pending_pop_response = false,
            .pending_pop_scope = .mux,
            .pending_pop_tab = 0,
            .pending_pop_pane = null,
            .uuid = uuid,
            .session_name = session_name,
            .session_name_owned = null,
            .ipc_server = ipc_server,
            .socket_path = socket_path,

            .osc_reply_target_uuid = null,
            .osc_reply_buf = .empty,
            .osc_reply_in_progress = false,
            .osc_reply_prev_esc = false,

            .pending_float_requests = std.AutoHashMap([32]u8, PendingFloatRequest).init(allocator),
        };
    }

    fn deinit(self: *State) void {
        var ses_shutdown_done = false;

        if (!self.detach_mode and self.ses_client.isConnected()) {
            // Persist sticky float metadata before shutdown.
            for (self.floats.items) |pane| {
                if (pane.sticky and pane.float_key != 0) {
                    if (pane.getPwd()) |cwd| {
                        self.ses_client.setSticky(pane.uuid, cwd, pane.float_key) catch {};
                    }
                }
            }

            // Tell ses this is a normal shutdown so it kills panes
            // instead of treating the disconnect as a crash.
            self.ses_client.shutdown(true) catch {};
            ses_shutdown_done = true;
        }

        // Deinit floats
        for (self.floats.items) |pane| {
            if (!self.detach_mode and self.ses_client.isConnected() and !ses_shutdown_done) {
                if (pane.sticky) {
                    if (pane.float_key != 0) {
                        if (pane.getPwd()) |cwd| {
                            self.ses_client.setSticky(pane.uuid, cwd, pane.float_key) catch {};
                        }
                    }
                    self.ses_client.orphanPane(pane.uuid) catch {};
                } else {
                    self.ses_client.killPane(pane.uuid) catch {};
                }
            }
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.floats.deinit(self.allocator);

        // Deinit all tabs - kill panes in ses if not detaching
        for (self.tabs.items) |*tab| {
            if (!self.detach_mode and self.ses_client.isConnected() and !ses_shutdown_done) {
                var pane_it = tab.layout.splits.valueIterator();
                while (pane_it.next()) |pane_ptr| {
                    self.ses_client.killPane(pane_ptr.*.uuid) catch {};
                }
            }
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.config.deinit();
        self.osc_reply_buf.deinit(self.allocator);
        self.renderer.deinit();
        self.ses_client.deinit();
        self.notifications.deinit();
        self.popups.deinit();
        var req_it = self.pending_float_requests.iterator();
        while (req_it.next()) |entry| {
            _ = posix.close(entry.value_ptr.fd);
            if (entry.value_ptr.result_path) |path| {
                self.allocator.free(path);
            }
        }
        self.pending_float_requests.deinit();
        if (self.ipc_server) |*srv| {
            srv.deinit();
        }
        if (self.socket_path) |path| {
            self.allocator.free(path);
        }
        if (self.session_name_owned) |owned| {
            self.allocator.free(owned);
        }
    }

    /// Get the current tab's layout
    fn currentLayout(self: *State) *Layout {
        return &self.tabs.items[self.active_tab].layout;
    }

    fn findPaneByUuid(self: *State, uuid: [32]u8) ?*Pane {
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

    /// Create a new tab with one pane
    fn createTab(self: *State) !void {
        const parent_uuid = self.getCurrentFocusedUuid();
        // Get cwd from currently focused pane, or use mux's cwd for first tab
        var cwd: ?[]const u8 = null;
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.tabs.items.len > 0) {
            if (self.currentLayout().getFocusedPane()) |focused| {
                // Refresh CWD from ses for pod panes
                cwd = self.refreshPaneCwd(focused);
            }
        } else {
            // First tab - use mux's current directory
            cwd = std.posix.getcwd(&cwd_buf) catch null;
        }

        var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, "tab", self.pop_config.carrier.notification);
        // Set ses client if connected (for new tabs after startup)
        if (self.ses_client.isConnected()) {
            tab.layout.setSesClient(&self.ses_client);
        }
        // Set pane notification config
        tab.layout.setPanePopConfig(&self.pop_config.pane.notification);
        const first_pane = try tab.layout.createFirstPane(cwd);
        try self.tabs.append(self.allocator, tab);
        self.active_tab = self.tabs.items.len - 1;
        self.syncPaneAux(first_pane, parent_uuid);
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncStateToSes();
    }

    /// Close the current tab
    fn closeCurrentTab(self: *State) bool {
        if (self.tabs.items.len <= 1) return false;
        const closing_tab = self.active_tab;

        // Handle tab-bound floats belonging to this tab
        var i: usize = 0;
        while (i < self.floats.items.len) {
            const fp = self.floats.items[i];
            if (fp.parent_tab) |parent| {
                if (parent == closing_tab) {
                    // Kill this tab-bound float
                    self.ses_client.killPane(fp.uuid) catch {};
                    fp.deinit();
                    self.allocator.destroy(fp);
                    _ = self.floats.orderedRemove(i);
                    // Clear active_floating if it was this float
                    if (self.active_floating) |afi| {
                        if (afi == i) {
                            self.active_floating = null;
                        } else if (afi > i) {
                            self.active_floating = afi - 1;
                        }
                    }
                    continue;
                } else if (parent > closing_tab) {
                    // Adjust index for floats on later tabs
                    fp.parent_tab = parent - 1;
                }
            }
            i += 1;
        }

        var tab = self.tabs.orderedRemove(self.active_tab);
        tab.deinit();
        if (self.active_tab >= self.tabs.items.len) {
            self.active_tab = self.tabs.items.len - 1;
        }
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncStateToSes();
        return true;
    }

    /// Adopt sticky panes from ses on startup
    /// Finds sticky panes matching current directory and configured sticky floats
    fn adoptStickyPanes(self: *State) void {
        if (!self.ses_client.isConnected()) return;

        // Get current working directory
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch return;

        // Check each float definition for sticky floats
        for (self.config.floats) |*float_def| {
            if (!float_def.sticky) continue;

            // Try to find a sticky pane in ses matching this directory + key
            const result = self.ses_client.findStickyPane(cwd, float_def.key) catch continue;
            if (result) |r| {
                // Found a sticky pane - adopt it as a float
                defer self.allocator.free(r.socket_path);
                self.adoptAsFloat(r.uuid, r.socket_path, r.pid, float_def, cwd) catch continue;
                self.notifications.showFor("Sticky float restored", 2000);
            }
        }
    }

    /// Adopt a pane from ses as a float with given float definition
    fn adoptAsFloat(self: *State, uuid: [32]u8, socket_path: []const u8, pid: std.posix.pid_t, float_def: *const core.FloatDef, cwd: []const u8) !void {
        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);

        const cfg = &self.config;

        // Use per-float settings or fall back to defaults
        const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
        const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
        const pos_x_pct: u16 = float_def.pos_x orelse 50;
        const pos_y_pct: u16 = float_def.pos_y orelse 50;
        const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
        const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
        const border_color = float_def.color orelse cfg.float_color;

        // Calculate outer frame size
        const avail_h = self.term_height - self.status_height;
        const outer_w = self.term_width * width_pct / 100;
        const outer_h = avail_h * height_pct / 100;

        // Calculate position based on percentage
        const max_x = if (self.term_width > outer_w) self.term_width - outer_w else 0;
        const max_y = if (avail_h > outer_h) avail_h - outer_h else 0;
        const outer_x = max_x * pos_x_pct / 100;
        const outer_y = max_y * pos_y_pct / 100;

        // Apply padding
        const pad_x: u16 = @intCast(@min(pad_x_cfg, outer_w / 4));
        const pad_y: u16 = @intCast(@min(pad_y_cfg, outer_h / 4));
        const content_x = outer_x + 1 + pad_x;
        const content_y = outer_y + 1 + pad_y;
        const content_w = if (outer_w > 2 + 2 * pad_x) outer_w - 2 - 2 * pad_x else 1;
        const content_h = if (outer_h > 2 + 2 * pad_y) outer_h - 2 - 2 * pad_y else 1;

        // Generate pane ID (floats use 100+ offset)
        const id: u16 = @intCast(100 + self.floats.items.len);

        _ = pid;
        // Initialize pane with the adopted pod
        try pane.initWithPod(self.allocator, id, content_x, content_y, content_w, content_h, socket_path, uuid);

        pane.floating = true;
        pane.focused = true;
        pane.float_key = float_def.key;
        pane.sticky = float_def.sticky;

        // For global floats (special or pwd), set per-tab visibility
        if (float_def.special or float_def.pwd) {
            pane.setVisibleOnTab(self.active_tab, true);
        } else {
            pane.visible = true;
        }

        // Store outer dimensions and style for border rendering
        pane.border_x = outer_x;
        pane.border_y = outer_y;
        pane.border_w = outer_w;
        pane.border_h = outer_h;
        pane.border_color = border_color;
        // Store percentages for resize recalculation
        pane.float_width_pct = @intCast(width_pct);
        pane.float_height_pct = @intCast(height_pct);
        pane.float_pos_x_pct = @intCast(pos_x_pct);
        pane.float_pos_y_pct = @intCast(pos_y_pct);
        pane.float_pad_x = @intCast(pad_x_cfg);
        pane.float_pad_y = @intCast(pad_y_cfg);

        // Store pwd for pwd floats
        if (float_def.pwd) {
            pane.is_pwd = true;
            pane.pwd_dir = self.allocator.dupe(u8, cwd) catch null;
        }

        // For tab-bound floats, set parent tab
        if (!float_def.special and !float_def.pwd) {
            pane.parent_tab = self.active_tab;
        }

        // Store style reference
        if (float_def.style) |*style| {
            pane.float_style = style;
        }

        // Configure pane notifications
        pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

        try self.floats.append(self.allocator, pane);
        // Don't set active_floating here - let user toggle it manually
    }

    /// Switch to next tab
    fn nextTab(self: *State) void {
        if (self.tabs.items.len > 1) {
            self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
            self.renderer.invalidate();
            self.force_full_render = true;
        }
    }

    /// Switch to previous tab
    fn prevTab(self: *State) void {
        if (self.tabs.items.len > 1) {
            self.active_tab = if (self.active_tab == 0) self.tabs.items.len - 1 else self.active_tab - 1;
            self.renderer.invalidate();
            self.force_full_render = true;
        }
    }

    /// Adopt first orphaned pane, replacing current focused pane
    fn adoptOrphanedPane(self: *State) bool {
        if (!self.ses_client.isConnected()) return false;

        // Get list of orphaned panes
        var panes: [32]OrphanedPaneInfo = undefined;
        const count = self.ses_client.listOrphanedPanes(&panes) catch return false;
        if (count == 0) return false;

        // Adopt the first one
        const result = self.ses_client.adoptPane(panes[0].uuid) catch return false;

        defer self.allocator.free(result.socket_path);

        // Get the current focused pane and replace it
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

    /// Serialize entire mux state to JSON for detach
    fn serializeState(self: *State) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        const writer = buf.writer(self.allocator);

        try writer.writeAll("{");

        // Mux UUID and session name (persistent identity)
        try writer.print("\"uuid\":\"{s}\",", .{self.uuid});
        try writer.print("\"session_name\":\"{s}\",", .{self.session_name});

        // Active tab/float
        try writer.print("\"active_tab\":{d},", .{self.active_tab});
        if (self.active_floating) |af| {
            try writer.print("\"active_floating\":{d},", .{af});
        } else {
            try writer.writeAll("\"active_floating\":null,");
        }

        // Tabs
        try writer.writeAll("\"tabs\":[");
        for (self.tabs.items, 0..) |*tab, ti| {
            if (ti > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"uuid\":\"{s}\",", .{tab.uuid});
            try writer.print("\"name\":\"{s}\",", .{tab.name});
            try writer.print("\"focused_split_id\":{d},", .{tab.layout.focused_split_id});
            try writer.print("\"next_split_id\":{d},", .{tab.layout.next_split_id});

            // Layout tree
            try writer.writeAll("\"tree\":");
            if (tab.layout.root) |root| {
                try self.serializeLayoutNode(writer, root);
            } else {
                try writer.writeAll("null");
            }

            // Splits in this tab
            try writer.writeAll(",\"splits\":[");
            var first_split = true;
            var pit = tab.layout.splits.iterator();
            while (pit.next()) |entry| {
                const pane = entry.value_ptr.*;
                if (!first_split) try writer.writeAll(",");
                first_split = false;
                try self.serializePane(writer, pane);
            }
            try writer.writeAll("]");

            try writer.writeAll("}");
        }
        try writer.writeAll("],");

        // Floats
        try writer.writeAll("\"floats\":[");
        for (self.floats.items, 0..) |pane, fi| {
            if (fi > 0) try writer.writeAll(",");
            try self.serializePane(writer, pane);
        }
        try writer.writeAll("]");

        try writer.writeAll("}");

        return buf.toOwnedSlice(self.allocator);
    }

    fn serializeLayoutNode(self: *State, writer: anytype, node: *LayoutNode) !void {
        _ = self;
        switch (node.*) {
            .pane => |id| {
                try writer.print("{{\"type\":\"pane\",\"id\":{d}}}", .{id});
            },
            .split => |split| {
                const dir_str: []const u8 = if (split.dir == .horizontal) "horizontal" else "vertical";
                try writer.print("{{\"type\":\"split\",\"dir\":\"{s}\",\"ratio\":{d},\"first\":", .{ dir_str, split.ratio });
                try serializeLayoutNode(undefined, writer, split.first);
                try writer.writeAll(",\"second\":");
                try serializeLayoutNode(undefined, writer, split.second);
                try writer.writeAll("}");
            },
        }
    }

    fn serializePane(self: *State, writer: anytype, pane: *Pane) !void {
        _ = self;
        try writer.writeAll("{");
        try writer.print("\"id\":{d},", .{pane.id});
        try writer.print("\"uuid\":\"{s}\",", .{pane.uuid});
        try writer.print("\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d},", .{ pane.x, pane.y, pane.width, pane.height });
        try writer.print("\"focused\":{},", .{pane.focused});
        try writer.print("\"floating\":{},", .{pane.floating});
        try writer.print("\"visible\":{},", .{pane.visible});
        try writer.print("\"tab_visible\":{d},", .{pane.tab_visible});
        try writer.print("\"float_key\":{d},", .{pane.float_key});
        try writer.print("\"border_x\":{d},\"border_y\":{d},\"border_w\":{d},\"border_h\":{d},", .{ pane.border_x, pane.border_y, pane.border_w, pane.border_h });
        try writer.print("\"float_width_pct\":{d},\"float_height_pct\":{d},", .{ pane.float_width_pct, pane.float_height_pct });
        try writer.print("\"float_pos_x_pct\":{d},\"float_pos_y_pct\":{d},", .{ pane.float_pos_x_pct, pane.float_pos_y_pct });
        try writer.print("\"float_pad_x\":{d},\"float_pad_y\":{d},", .{ pane.float_pad_x, pane.float_pad_y });
        try writer.print("\"is_pwd\":{},", .{pane.is_pwd});
        try writer.print("\"sticky\":{}", .{pane.sticky});
        if (pane.parent_tab) |pt| {
            try writer.print(",\"parent_tab\":{d}", .{pt});
        }
        if (pane.pwd_dir) |pwd| {
            try writer.print(",\"pwd_dir\":\"{s}\"", .{pwd});
        }
        try writer.writeAll("}");
    }

    /// Reattach to a detached session, restoring full state
    fn reattachSession(self: *State, session_id_prefix: []const u8) bool {
        if (!self.ses_client.isConnected()) return false;

        // Try to reattach session (server supports prefix matching)
        const result = self.ses_client.reattachSession(session_id_prefix) catch return false;
        if (result == null) return false;

        const reattach_result = result.?;
        defer {
            self.allocator.free(reattach_result.mux_state_json);
            self.allocator.free(reattach_result.pane_uuids);
        }

        // Parse the mux state JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, reattach_result.mux_state_json, .{}) catch return false;
        defer parsed.deinit();

        const root = parsed.value.object;

        // Restore mux UUID (persistent identity)
        if (root.get("uuid")) |uuid_val| {
            const uuid_str = uuid_val.string;
            if (uuid_str.len == 32) {
                @memcpy(&self.uuid, uuid_str[0..32]);
            }
        }

        // Restore session name (must dupe since parsed JSON will be freed)
        if (root.get("session_name")) |name_val| {
            // Free previous owned name if any
            if (self.session_name_owned) |old| {
                self.allocator.free(old);
            }
            // Dupe the name from JSON
            const duped = self.allocator.dupe(u8, name_val.string) catch return false;
            self.session_name = duped;
            self.session_name_owned = duped;
        }

        // Re-register with ses using restored UUID and session_name
        self.ses_client.updateSession(self.uuid, self.session_name) catch {};

        // Restore active tab/floating
        if (root.get("active_tab")) |at| {
            self.active_tab = @intCast(at.integer);
        }
        if (root.get("active_floating")) |af| {
            self.active_floating = if (af == .null) null else @intCast(af.integer);
        }

        // Build a map of UUID -> pod socket path for pane adoption
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

        // Restore tabs
        if (root.get("tabs")) |tabs_arr| {
            for (tabs_arr.array.items) |tab_val| {
                const tab_obj = tab_val.object;
                const name_json = (tab_obj.get("name") orelse continue).string;
                const focused_split_id: u16 = @intCast((tab_obj.get("focused_split_id") orelse continue).integer);
                const next_split_id: u16 = @intCast((tab_obj.get("next_split_id") orelse continue).integer);

                // Dupe the name since parsed JSON will be freed
                const name = self.allocator.dupe(u8, name_json) catch continue;
                var tab = Tab.init(self.allocator, self.layout_width, self.layout_height, name, self.pop_config.carrier.notification);

                // Restore tab UUID if present
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

                // Restore splits
                if (tab_obj.get("splits")) |splits_arr| {
                    for (splits_arr.array.items) |pane_val| {
                        const pane_obj = pane_val.object;
                        const pane_id: u16 = @intCast((pane_obj.get("id") orelse continue).integer);
                        const uuid_str = (pane_obj.get("uuid") orelse continue).string;
                        if (uuid_str.len != 32) continue;

                        // Convert to [32]u8 for lookup
                        var uuid_arr: [32]u8 = undefined;
                        @memcpy(&uuid_arr, uuid_str[0..32]);

                        if (uuid_socket_map.get(uuid_arr)) |sock| {
                            const pane = self.allocator.create(Pane) catch continue;

                            pane.initWithPod(self.allocator, pane_id, 0, 0, self.layout_width, self.layout_height, sock, uuid_arr) catch {
                                self.allocator.destroy(pane);
                                continue;
                            };

                            // Restore pane properties
                            pane.focused = if (pane_obj.get("focused")) |f| (f == .bool and f.bool) else false;

                            tab.layout.splits.put(pane_id, pane) catch {
                                pane.deinit();
                                self.allocator.destroy(pane);
                                continue;
                            };
                        }
                    }
                }

                // Restore layout tree
                if (tab_obj.get("tree")) |tree_val| {
                    if (tree_val != .null) {
                        tab.layout.root = self.deserializeLayoutNode(tree_val.object) catch null;
                    }
                }

                self.tabs.append(self.allocator, tab) catch continue;
            }
        }

        // Restore floats
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

                    // Restore float properties
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

                    // Configure pane notifications
                    pane.configureNotificationsFromPop(&self.pop_config.pane.notification);

                    self.floats.append(self.allocator, pane) catch {
                        pane.deinit();
                        self.allocator.destroy(pane);
                        continue;
                    };
                }
            }
        }

        // Recalculate all layouts for current terminal size
        for (self.tabs.items) |*tab| {
            tab.layout.resize(self.layout_width, self.layout_height);
        }

        // Recalculate floating pane positions
        resizeFloatingPanes(self);

        self.renderer.invalidate();
        self.force_full_render = true;
        return self.tabs.items.len > 0;
    }

    fn deserializeLayoutNode(self: *State, obj: std.json.ObjectMap) !*LayoutNode {
        const node = try self.allocator.create(LayoutNode);
        errdefer self.allocator.destroy(node);

        const node_type = (obj.get("type") orelse return error.InvalidNode).string;

        if (std.mem.eql(u8, node_type, "pane")) {
            const id: u16 = @intCast((obj.get("id") orelse return error.InvalidNode).integer);
            node.* = .{ .pane = id };
        } else if (std.mem.eql(u8, node_type, "split")) {
            const dir_str = (obj.get("dir") orelse return error.InvalidNode).string;
            const dir: SplitDir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical;
            const ratio_val = obj.get("ratio") orelse return error.InvalidNode;
            const ratio: f32 = switch (ratio_val) {
                .float => @floatCast(ratio_val.float),
                .integer => @floatFromInt(ratio_val.integer),
                else => return error.InvalidNode,
            };
            const first_obj = (obj.get("first") orelse return error.InvalidNode).object;
            const second_obj = (obj.get("second") orelse return error.InvalidNode).object;

            const first = try self.deserializeLayoutNode(first_obj);
            errdefer self.allocator.destroy(first);
            const second = try self.deserializeLayoutNode(second_obj);

            node.* = .{ .split = .{
                .dir = dir,
                .ratio = ratio,
                .first = first,
                .second = second,
            } };
        } else {
            return error.InvalidNode;
        }

        return node;
    }

    /// Attach to orphaned pane by UUID prefix (for --attach CLI)
    fn attachOrphanedPane(self: *State, uuid_prefix: []const u8) bool {
        if (!self.ses_client.isConnected()) return false;

        // Get list of orphaned panes and find matching UUID
        var tabs: [32]OrphanedPaneInfo = undefined;
        const count = self.ses_client.listOrphanedPanes(&tabs) catch return false;

        for (tabs[0..count]) |p| {
            if (std.mem.startsWith(u8, &p.uuid, uuid_prefix)) {
                // Found matching pane, adopt it
                const result = self.ses_client.adoptPane(p.uuid) catch return false;

                // Create a new tab with this pane
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

                // Add pane to layout manually
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

    /// Sync current state to ses for crash recovery
    fn syncStateToSes(self: *State) void {
        if (!self.ses_client.isConnected()) return;

        const mux_state_json = self.serializeState() catch return;
        defer self.allocator.free(mux_state_json);

        self.ses_client.syncState(mux_state_json) catch {};
    }

    /// Get UUID of currently focused pane (in layout or floating)
    fn getCurrentFocusedUuid(self: *State) ?[32]u8 {
        if (self.active_floating) |idx| {
            if (idx < self.floats.items.len) {
                return self.floats.items[idx].uuid;
            }
        }
        // Guard against no tabs existing yet
        if (self.tabs.items.len == 0) return null;
        if (self.currentLayout().getFocusedPane()) |pane| {
            return pane.uuid;
        }
        return null;
    }

    /// Sync auxiliary pane info to ses (for newly created panes)
    fn syncPaneAux(self: *State, pane: *Pane, created_from: ?[32]u8) void {
        // Only sync if connected and pane has a valid UUID
        if (!self.ses_client.isConnected()) return;
        if (pane.uuid[0] == 0) return; // Skip if UUID not set

        // If this pane is focused, unfocus all others first
        if (pane.focused) {
            self.unfocusAllPanes();
            pane.focused = true; // Restore since unfocusAllPanes cleared it
        }

        const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
        const cursor = pane.getCursorPos();
        const cursor_style = pane.vt.getCursorStyle();
        const cursor_visible = pane.vt.isCursorVisible();
        const alt_screen = pane.vt.inAltScreen();
        const layout_path = getLayoutPath(self, pane) catch null;
        defer if (layout_path) |path| self.allocator.free(path);
        // For new panes, focused_from = created_from (focus moved from parent to new pane)
        const focused_from = if (pane.focused) created_from else null;
        self.ses_client.updatePaneAux(
            pane.uuid,
            pane.floating,
            pane.focused,
            pane_type,
            created_from,
            focused_from,
            .{ .x = cursor.x, .y = cursor.y },
            cursor_style,
            cursor_visible,
            alt_screen,
            .{ .cols = pane.width, .rows = pane.height },
            pane.getRealCwd(),
            pane.getFgProcess(),
            pane.getFgPid(),
            layout_path,
        ) catch {
            // Silently ignore errors - pane might not exist in ses yet or anymore
        };
    }

    /// Unfocus all panes in ses (call before focusing a new pane)
    fn unfocusAllPanes(self: *State) void {
        if (!self.ses_client.isConnected()) return;

        // Unfocus all splits in all tabs
        for (self.tabs.items) |*tab| {
            var pane_it = tab.layout.splitIterator();
            while (pane_it.next()) |p| {
                if (p.*.uuid[0] != 0) {
                    p.*.focused = false;
                    const pane_type: SesClient.PaneType = if (p.*.floating) .float else .split;
                    const cursor = p.*.getCursorPos();
                    const cursor_style = p.*.vt.getCursorStyle();
                    const cursor_visible = p.*.vt.isCursorVisible();
                    const alt_screen = p.*.vt.inAltScreen();
                    const layout_path = getLayoutPath(self, p.*) catch null;
                    defer if (layout_path) |path| self.allocator.free(path);
                    self.ses_client.updatePaneAux(
                        p.*.uuid,
                        p.*.floating,
                        false,
                        pane_type,
                        null,
                        null,
                        .{ .x = cursor.x, .y = cursor.y },
                        cursor_style,
                        cursor_visible,
                        alt_screen,
                        .{ .cols = p.*.width, .rows = p.*.height },
                        null,
                        null,
                        null,
                        layout_path,
                    ) catch {};
                }
            }
        }

        // Unfocus all floats
        for (self.floats.items) |fp| {
            if (fp.uuid[0] != 0) {
                fp.focused = false;
                const cursor = fp.getCursorPos();
                const cursor_style = fp.vt.getCursorStyle();
                const cursor_visible = fp.vt.isCursorVisible();
                const alt_screen = fp.vt.inAltScreen();
                const layout_path = getLayoutPath(self, fp) catch null;
                defer if (layout_path) |path| self.allocator.free(path);
                self.ses_client.updatePaneAux(
                    fp.uuid,
                    fp.floating,
                    false,
                    .float,
                    null,
                    null,
                    .{ .x = cursor.x, .y = cursor.y },
                    cursor_style,
                    cursor_visible,
                    alt_screen,
                    .{ .cols = fp.width, .rows = fp.height },
                    null,
                    null,
                    null,
                    layout_path,
                ) catch {};
            }
        }
    }

    /// Sync focus change to ses (updates is_focused and focused_from)
    fn syncPaneFocus(self: *State, pane: *Pane, focused_from: ?[32]u8) void {
        // Only sync if connected and pane has a valid UUID
        if (!self.ses_client.isConnected()) return;
        if (pane.uuid[0] == 0) return; // Skip if UUID not set

        // First unfocus all panes
        self.unfocusAllPanes();

        // Then focus this pane
        pane.focused = true;
        const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
        const cursor = pane.getCursorPos();
        const cursor_style = pane.vt.getCursorStyle();
        const cursor_visible = pane.vt.isCursorVisible();
        const alt_screen = pane.vt.inAltScreen();
        const layout_path = getLayoutPath(self, pane) catch null;
        defer if (layout_path) |path| self.allocator.free(path);
        self.ses_client.updatePaneAux(
            pane.uuid,
            pane.floating,
            true, // is_focused
            pane_type,
            null, // don't update created_from on focus change
            focused_from,
            .{ .x = cursor.x, .y = cursor.y },
            cursor_style,
            cursor_visible,
            alt_screen,
            .{ .cols = pane.width, .rows = pane.height },
            pane.getRealCwd(),
            pane.getFgProcess(),
            pane.getFgPid(),
            layout_path,
        ) catch {
            // Silently ignore errors - pane might not exist in ses
        };

        // Sync full state so hexe com list shows updated focus
        self.syncStateToSes();
    }

    /// Sync that a pane lost focus
    fn syncPaneUnfocus(self: *State, pane: *Pane) void {
        // Only sync if connected and pane has a valid UUID
        if (!self.ses_client.isConnected()) return;
        if (pane.uuid[0] == 0) return; // Skip if UUID not set

        const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
        const cursor = pane.getCursorPos();
        const cursor_style = pane.vt.getCursorStyle();
        const cursor_visible = pane.vt.isCursorVisible();
        const alt_screen = pane.vt.inAltScreen();
        const layout_path = getLayoutPath(self, pane) catch null;
        defer if (layout_path) |path| self.allocator.free(path);
        self.ses_client.updatePaneAux(
            pane.uuid,
            pane.floating,
            false, // is_focused = false
            pane_type,
            null,
            null,
            .{ .x = cursor.x, .y = cursor.y },
            cursor_style,
            cursor_visible,
            alt_screen,
            .{ .cols = pane.width, .rows = pane.height },
            pane.getRealCwd(),
            pane.getFgProcess(),
            pane.getFgPid(),
            layout_path,
        ) catch {
            // Silently ignore errors - pane might not exist in ses
        };
    }

    /// Refresh CWD cache from ses for a pod pane.
    /// For pod panes, queries ses daemon for /proc/<pid>/cwd and caches it.
    /// Returns the best available CWD (OSC 7, local /proc, or ses cache).
    fn refreshPaneCwd(self: *State, pane: *Pane) ?[]const u8 {
        // For pod panes, query ses for CWD from /proc and cache it
        switch (pane.backend) {
            .pod => {
                if (self.ses_client.getPaneCwd(pane.uuid)) |cwd| {
                    pane.setSesCwd(cwd);
                }
            },
            .local => {},
        }
        return pane.getRealCwd();
    }

    /// Fetch a spawn-safe CWD for pod panes (prefer /proc from ses).
    fn getSpawnCwd(self: *State, pane: *Pane) ?[]const u8 {
        switch (pane.backend) {
            .pod => {
                if (self.ses_client.getPaneCwd(pane.uuid)) |cwd| {
                    pane.setSesCwd(cwd);
                    return cwd;
                }
            },
            .local => {},
        }
        return pane.getRealCwd();
    }

    /// Periodically sync focused pane info (CWD, fg_process) to ses
    fn syncFocusedPaneInfo(self: *State) void {
        if (!self.ses_client.isConnected()) return;

        // Get the currently focused pane
        const pane = if (self.active_floating) |idx| blk: {
            if (idx < self.floats.items.len) break :blk self.floats.items[idx];
            break :blk @as(?*Pane, null);
        } else self.currentLayout().getFocusedPane();

        if (pane == null) return;
        const p = pane.?;
        if (p.uuid[0] == 0) return;

        // Refresh CWD cache for pod panes
        _ = self.refreshPaneCwd(p);

        const pane_type: SesClient.PaneType = if (p.floating) .float else .split;
        const cursor = p.getCursorPos();
        const cursor_style = p.vt.getCursorStyle();
        const cursor_visible = p.vt.isCursorVisible();
        const alt_screen = p.vt.inAltScreen();
        const layout_path = getLayoutPath(self, p) catch null;
        defer if (layout_path) |path| self.allocator.free(path);
        self.ses_client.updatePaneAux(
            p.uuid,
            p.floating,
            true,
            pane_type,
            null, // don't update created_from
            null, // don't update focused_from
            .{ .x = cursor.x, .y = cursor.y },
            cursor_style,
            cursor_visible,
            alt_screen,
            .{ .cols = p.width, .rows = p.height },
            p.getRealCwd(), // Use cached CWD after refresh
            null,
            null,
            layout_path,
        ) catch {};
    }
};

fn getLayoutPath(state: *State, pane: *Pane) !?[]const u8 {
    if (pane.floating) {
        if (pane.parent_tab) |tab_idx| {
            return try std.fmt.allocPrint(state.allocator, "tab:{d}/float:{d}", .{ tab_idx, pane.id });
        }
        return try std.fmt.allocPrint(state.allocator, "float:{d}", .{pane.id});
    }

    for (state.tabs.items, 0..) |*tab, ti| {
        var pane_it = tab.layout.splitIterator();
        while (pane_it.next()) |p| {
            if (p.* == pane) {
                return try std.fmt.allocPrint(state.allocator, "tab:{d}/split:{d}", .{ ti, pane.id });
            }
        }
    }

    return null;
}

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

fn writeJsonEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

fn handleBlockingFloatCompletion(state: *State, pane: *Pane) void {
    const entry = state.pending_float_requests.fetchRemove(pane.uuid) orelse return;
    var conn = core.ipc.Connection{ .fd = entry.value.fd };
    defer conn.close();

    const exit_code = pane.getExitCode();
    var stdout: ?[]u8 = null;
    defer if (stdout) |out| state.allocator.free(out);

    if (entry.value.result_path) |path| {
        const content = std.fs.cwd().readFileAlloc(state.allocator, path, 1024 * 1024) catch null;
        if (content) |buf| {
            const trimmed = std.mem.trimRight(u8, buf, " \n\r\t");
            if (trimmed.len > 0) {
                stdout = state.allocator.dupe(u8, trimmed) catch null;
            }
            state.allocator.free(buf);
        }
        std.fs.cwd().deleteFile(path) catch {};
        state.allocator.free(path);
    }
    if (stdout == null) {
        stdout = pane.captureOutput(state.allocator) catch null;
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.allocator);
    var writer = buf.writer(state.allocator);

    writer.print("{{\"type\":\"float_result\",\"uuid\":\"{s}\",\"exit_code\":{d},\"stdout\":\"", .{ pane.uuid, exit_code }) catch return;
    if (stdout) |out| {
        writeJsonEscaped(writer, out) catch return;
    }
    writer.writeAll("\"}\n") catch return;

    conn.send(buf.items) catch {};
}

/// Arguments for mux commands
pub const MuxArgs = struct {
    name: ?[]const u8 = null,
    attach: ?[]const u8 = null,
    notify_message: ?[]const u8 = null,
    list: bool = false,
    debug: bool = false,
    log_file: ?[]const u8 = null,
};

/// Entry point for mux - can be called directly from unified CLI
pub fn run(mux_args: MuxArgs) !void {
    const allocator = std.heap.page_allocator;

    // Handle --notify: send to parent mux and exit
    if (mux_args.notify_message) |msg| {
        sendNotifyToParentMux(allocator, msg);
        return;
    }

    // Handle --list: show detached sessions and orphaned panes
    if (mux_args.list) {
        // Temporary connection for listing - generate a dummy UUID and name
        const tmp_uuid = core.ipc.generateUuid();
        const tmp_name = core.ipc.generateSessionName();
        var ses = SesClient.init(allocator, tmp_uuid, tmp_name, false, false, null); // keepalive=false for temp connection
        defer ses.deinit();
        ses.connect() catch {
            std.debug.print("Could not connect to ses daemon\n", .{});
            return;
        };

        // List detached sessions
        var sessions: [16]ses_client.DetachedSessionInfo = undefined;
        const sess_count = ses.listSessions(&sessions) catch 0;
        if (sess_count > 0) {
            std.debug.print("Detached sessions:\n", .{});
            for (sessions[0..sess_count]) |s| {
                const name = s.session_name[0..s.session_name_len];
                std.debug.print("  {s} [{s}] {d} tabs - attach with: hexe mux attach {s}\n", .{ name, s.session_id[0..8], s.pane_count, name });
            }
        }

        // List orphaned panes
        var tabs: [32]OrphanedPaneInfo = undefined;
        const count = ses.listOrphanedPanes(&tabs) catch 0;
        if (count > 0) {
            std.debug.print("Orphaned tabs (disowned):\n", .{});
            for (tabs[0..count]) |p| {
                std.debug.print("  [{s}] pid={d}\n", .{ p.uuid[0..8], p.pid });
            }
        }

        if (sess_count == 0 and count == 0) {
            std.debug.print("No detached sessions or orphaned panes\n", .{});
        }
        return;
    }

    // Handle --attach: attach to detached session by name or UUID prefix
    if (mux_args.attach) |uuid_arg| {
        if (uuid_arg.len < 3) {
            std.debug.print("Session name/UUID too short (need at least 3 chars)\n", .{});
            return;
        }
        // Will be handled after state init
    }

    // Redirect stderr to a log file or /dev/null to avoid display corruption
    redirectStderr(mux_args.log_file);
    debug_enabled = mux_args.debug;
    debugLog("started", .{});

    // Get terminal size
    const size = terminal.getTermSize();

    // Initialize state
    var state = try State.init(allocator, size.cols, size.rows, mux_args.debug, mux_args.log_file);
    defer state.deinit();

    // Set custom session name if provided
    if (mux_args.name) |custom_name| {
        const duped = allocator.dupe(u8, custom_name) catch null;
        if (duped) |d| {
            state.session_name = d;
            state.session_name_owned = d;
        }
    }

    // Set HEXE_MUX_SOCKET environment for child processes
    if (state.socket_path) |path| {
        const path_z = allocator.dupeZ(u8, path) catch null;
        if (path_z) |p| {
            _ = c.setenv("HEXE_MUX_SOCKET", p.ptr, 1);
            allocator.free(p);
        }
    }

    // Connect to ses daemon FIRST (start it if needed)
    state.ses_client.connect() catch {};
    debugLog("ses connected (started={})", .{state.ses_client.just_started_daemon});

    // Show notification if we just started the daemon
    if (state.ses_client.just_started_daemon) {
        state.notifications.showFor("ses daemon started", 2000);
    }

    // Handle --attach: try session first, then orphaned pane
    if (mux_args.attach) |uuid_prefix| {
        // First try to reattach a detached session
        if (state.reattachSession(uuid_prefix)) {
            state.notifications.show("Session reattached");
        } else if (state.attachOrphanedPane(uuid_prefix)) {
            // Fall back to orphaned pane
            state.notifications.show("Attached to orphaned pane");
        } else {
            // Fallback to creating new tab
            try state.createTab();
            state.notifications.show("Session/pane not found, created new");
        }
    } else {
        // Create first tab with one pane (will use ses if connected)
        try state.createTab();
    }

    // Auto-adopt sticky panes from ses for this directory
    state.adoptStickyPanes();

    // Continue with main loop
    try runMainLoop(&state);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var mux_args = MuxArgs{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if ((std.mem.eql(u8, arg, "--notify") or std.mem.eql(u8, arg, "-n")) and i + 1 < args.len) {
            i += 1;
            mux_args.notify_message = args[i];
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            mux_args.list = true;
        } else if ((std.mem.eql(u8, arg, "--attach") or std.mem.eql(u8, arg, "-a")) and i + 1 < args.len) {
            i += 1;
            mux_args.attach = args[i];
        } else if ((std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-N")) and i + 1 < args.len) {
            i += 1;
            mux_args.name = args[i];
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            mux_args.debug = true;
        } else if ((std.mem.eql(u8, arg, "--logfile") or std.mem.eql(u8, arg, "-L")) and i + 1 < args.len) {
            i += 1;
            mux_args.log_file = args[i];
        }
    }

    try run(mux_args);
}

fn redirectStderr(log_file: ?[]const u8) void {
    var redirected = false;
    if (log_file) |path| {
        if (path.len > 0) {
            const logfd = posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch null;
            if (logfd) |fd| {
                posix.dup2(fd, posix.STDERR_FILENO) catch {};
                if (fd > 2) posix.close(fd);
                redirected = true;
            }
        }
    }

    if (redirected) return;

    const devnull = std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only }) catch return;
    posix.dup2(devnull.handle, posix.STDERR_FILENO) catch {};
    devnull.close();
}

fn runMainLoop(state: *State) !void {
    const allocator = state.allocator;

    // Enter raw mode
    const orig_termios = try terminal.enableRawMode(posix.STDIN_FILENO);
    defer terminal.disableRawMode(posix.STDIN_FILENO, orig_termios) catch {};

    // Enter alternate screen and reset it
    const stdout = std.fs.File.stdout();
    // Sequence:
    // ESC[?1049h    - Enter alternate screen buffer (FIRST - before any reset)
    // ESC[2J        - Clear entire alternate screen
    // ESC[H         - Cursor to home position (1,1)
    // ESC[0m        - Reset all SGR attributes
    // ESC(B         - Set G0 charset to ASCII (US-ASCII)
    // ESC)0         - Set G1 charset to DEC Special Graphics
    // SI (0x0F)     - Shift In - select G0 charset
    // ESC[?25l      - Hide cursor
    // ESC[?1000h    - Enable mouse click tracking
    // ESC[?1006h    - Enable SGR mouse mode
    // Also clear scrollback (CSI 3 J) so we don't see prior content.
    try stdout.writeAll("\x1b[?1049h\x1b[2J\x1b[3J\x1b[H\x1b[0m\x1b(B\x1b)0\x0f\x1b[?25l\x1b[?1000h\x1b[?1006h");
    // On exit: disable mouse, show cursor, reset attributes, leave alternate screen
    defer stdout.writeAll("\x1b[?1006l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l") catch {};

    // Build poll fds
    var poll_fds: [17]posix.pollfd = undefined; // stdin + up to 16 panes
    var buffer: [1024 * 1024]u8 = undefined; // Larger buffer for efficiency

    // Frame timing
    var last_render: i64 = std.time.milliTimestamp();
    var last_status_update: i64 = last_render;
    var last_pane_sync: i64 = last_render;
    const status_update_interval: i64 = 250; // Update status bar every 250ms
    const pane_sync_interval: i64 = 1000; // Sync pane info (CWD, process) every 1s

    // Main loop
    while (state.running) {
        // Clear skip flag from previous iteration
        state.skip_dead_check = false;

        // Check for terminal resize
        {
            const new_size = terminal.getTermSize();
            if (new_size.cols != state.term_width or new_size.rows != state.term_height) {
                state.term_width = new_size.cols;
                state.term_height = new_size.rows;
                const status_h: u16 = if (state.config.tabs.status.enabled) 1 else 0;
                state.status_height = status_h;
                state.layout_width = new_size.cols;
                state.layout_height = new_size.rows - status_h;

                // Resize all tabs
                for (state.tabs.items) |*tab| {
                    tab.layout.resize(state.layout_width, state.layout_height);
                }

                // Resize floats based on their stored percentages
                resizeFloatingPanes(state);

                // Resize renderer and force full redraw
                state.renderer.resize(new_size.cols, new_size.rows) catch {};
                state.renderer.invalidate();
                state.needs_render = true;
                state.force_full_render = true;
            }
        }

        // Proactively check for dead floats before polling
        {
            var fi: usize = 0;
            while (fi < state.floats.items.len) {
                if (!state.floats.items[fi].isAlive()) {
                    // Check if this was the active float
                    const was_active = if (state.active_floating) |af| af == fi else false;

                    const pane = state.floats.orderedRemove(fi);

                    handleBlockingFloatCompletion(state, pane);

                    // Kill in ses (dead panes don't need to be orphaned)
                    if (state.ses_client.isConnected()) {
                        state.ses_client.killPane(pane.uuid) catch {};
                    }

                    pane.deinit();
                    state.allocator.destroy(pane);
                    state.needs_render = true;
                    state.syncStateToSes();

                    // Clear focus if this was the active float, sync focus to tiled pane
                    if (was_active) {
                        state.active_floating = null;
                        if (state.currentLayout().getFocusedPane()) |tiled| {
                            state.syncPaneFocus(tiled, null);
                        }
                    }
                    // Don't increment fi, next item shifted into this position
                } else {
                    fi += 1;
                }
            }
            // Ensure active_floating is valid
            if (state.active_floating) |af| {
                if (af >= state.floats.items.len) {
                    state.active_floating = if (state.floats.items.len > 0)
                        state.floats.items.len - 1
                    else
                        null;
                }
            }
        }

        // Build poll list: stdin + all pane PTYs
        var fd_count: usize = 1;
        poll_fds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };

        var pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.*.getFd(), .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add floats
        for (state.floats.items) |pane| {
            if (fd_count < poll_fds.len) {
                poll_fds[fd_count] = .{ .fd = pane.getFd(), .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add ses connection fd if connected
        var ses_fd_idx: ?usize = null;
        if (state.ses_client.conn) |conn| {
            if (fd_count < poll_fds.len) {
                ses_fd_idx = fd_count;
                poll_fds[fd_count] = .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Add IPC server fd for incoming connections
        var ipc_fd_idx: ?usize = null;
        if (state.ipc_server) |srv| {
            if (fd_count < poll_fds.len) {
                ipc_fd_idx = fd_count;
                poll_fds[fd_count] = .{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 };
                fd_count += 1;
            }
        }

        // Calculate poll timeout - wait for next frame, status update, or input
        const now = std.time.milliTimestamp();
        const since_render = now - last_render;
        const since_status = now - last_status_update;
        const until_status: i64 = @max(0, status_update_interval - since_status);
        const frame_timeout: i32 = if (!state.needs_render) 100 else if (since_render >= 16) 0 else @intCast(16 - since_render);
        const timeout: i32 = @intCast(@min(frame_timeout, until_status));
        _ = posix.poll(poll_fds[0..fd_count], timeout) catch continue;

        // Check if status bar needs periodic update
        const now2 = std.time.milliTimestamp();
        if (now2 - last_status_update >= status_update_interval) {
            state.needs_render = true;
            last_status_update = now2;
        }

        // Periodic sync of pane info (CWD, fg_process) to ses
        if (now2 - last_pane_sync >= pane_sync_interval) {
            last_pane_sync = now2;
            state.syncFocusedPaneInfo();
        }

        // Handle stdin
        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buffer) catch break;
            if (n == 0) break;
            handleInput(state, buffer[0..n]);
        }

        // Handle ses messages
        if (ses_fd_idx) |sidx| {
            if (poll_fds[sidx].revents & posix.POLL.IN != 0) {
                handleSesMessage(state, &buffer);
            }
        }

        // Handle IPC connections (for --notify)
        if (ipc_fd_idx) |iidx| {
            if (poll_fds[iidx].revents & posix.POLL.IN != 0) {
                handleIpcConnection(state, &buffer);
            }
        }

        // Handle PTY output
        var idx: usize = 1;
        var dead_splits: std.ArrayList(u16) = .empty;
        defer dead_splits.deinit(allocator);

        pane_it = state.currentLayout().splitIterator();
        while (pane_it.next()) |pane| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.*.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.*.takeOscExpectResponse()) {
                            state.osc_reply_target_uuid = pane.*.uuid;
                        }
                        if (pane.*.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_splits.append(allocator, pane.*.id) catch {};
                }
                idx += 1;
            }
        }

        // Handle floating pane output
        var dead_floating: std.ArrayList(usize) = .empty;
        defer dead_floating.deinit(allocator);

        for (state.floats.items, 0..) |pane, fi| {
            if (idx < fd_count) {
                if (poll_fds[idx].revents & posix.POLL.IN != 0) {
                    if (pane.poll(&buffer)) |had_data| {
                        if (had_data) state.needs_render = true;
                        if (pane.takeOscExpectResponse()) {
                            state.osc_reply_target_uuid = pane.uuid;
                        }
                        if (pane.did_clear) {
                            state.force_full_render = true;
                            state.renderer.invalidate();
                        }
                    } else |_| {}
                }
                if (poll_fds[idx].revents & posix.POLL.HUP != 0) {
                    dead_floating.append(allocator, fi) catch {};
                }
                idx += 1;
            }
        }

        // Remove dead floats (in reverse order to preserve indices)
        var df_idx: usize = dead_floating.items.len;
        while (df_idx > 0) {
            df_idx -= 1;
            const fi = dead_floating.items[df_idx];
            // Check if this was the active float before removing
            const was_active = if (state.active_floating) |af| af == fi else false;

            const pane = state.floats.orderedRemove(fi);
            handleBlockingFloatCompletion(state, pane);
            pane.deinit();
            state.allocator.destroy(pane);
            state.needs_render = true;

            // Clear focus if this was the active float
            if (was_active) {
                state.active_floating = null;
            }
        }
        // Ensure active_floating is still valid
        if (state.active_floating) |af| {
            if (af >= state.floats.items.len) {
                state.active_floating = null;
            }
        }

        // Remove dead splits (skip if just respawned a shell)
        if (!state.skip_dead_check) {
            for (dead_splits.items) |_| {
                if (state.currentLayout().splitCount() > 1) {
                    // Multiple splits in tab - just close this one
                    _ = state.currentLayout().closeFocused();
                    // Sync focus to new pane and update ses state
                    if (state.currentLayout().getFocusedPane()) |new_pane| {
                        state.syncPaneFocus(new_pane, null);
                    }
                    state.syncStateToSes();
                    state.needs_render = true;
                } else if (state.tabs.items.len > 1) {
                    // Only 1 pane but multiple tabs - close this tab
                    _ = state.closeCurrentTab();
                    state.needs_render = true;
                } else {
                    // Last pane in last tab - confirm before exit if enabled
                    if (state.config.confirm_on_exit and state.pending_action == null) {
                        state.pending_action = .exit;
                        state.exit_from_shell_death = true;
                        state.popups.showConfirm("Shell exited. Close mux?", .{}) catch {};
                        state.needs_render = true;
                    } else if (state.pending_action != .exit or !state.exit_from_shell_death) {
                        state.running = false;
                    }
                }
            }
        }

        // Update MUX realm notifications
        if (state.notifications.update()) {
            state.needs_render = true;
        }

        // Update MUX realm popups (check for timeout)
        const mux_popup_changed = state.popups.update();
        if (mux_popup_changed) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response
            if (state.pending_pop_response and state.pending_pop_scope == .mux and !state.popups.isBlocked()) {
                sendPopResponse(state);
            }
        }

        // Update TAB realm notifications (current tab only)
        if (state.tabs.items[state.active_tab].notifications.update()) {
            state.needs_render = true;
        }

        // Update TAB realm popups (check for timeout)
        if (state.tabs.items[state.active_tab].popups.update()) {
            state.needs_render = true;
            // Check if a popup timed out and we need to send response
            if (state.pending_pop_response and state.pending_pop_scope == .tab and !state.tabs.items[state.active_tab].popups.isBlocked()) {
                sendPopResponse(state);
            }
        }

        // Update PANE realm notifications (splits)
        var notif_pane_it = state.currentLayout().splitIterator();
        while (notif_pane_it.next()) |pane| {
            if (pane.*.updateNotifications()) {
                state.needs_render = true;
            }
            // Update PANE realm popups (check for timeout)
            if (pane.*.updatePopups()) {
                state.needs_render = true;
                // Check if a popup timed out and we need to send response
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane.* and !pane.*.popups.isBlocked()) {
                            sendPopResponse(state);
                        }
                    }
                }
            }
        }

        // Update PANE realm notifications (floats)
        for (state.floats.items) |pane| {
            if (pane.updateNotifications()) {
                state.needs_render = true;
            }
            // Update PANE realm popups (check for timeout)
            if (pane.updatePopups()) {
                state.needs_render = true;
                // Check if a popup timed out and we need to send response
                if (state.pending_pop_response and state.pending_pop_scope == .pane) {
                    if (state.pending_pop_pane) |pending_pane| {
                        if (pending_pane == pane and !pane.popups.isBlocked()) {
                            sendPopResponse(state);
                        }
                    }
                }
            }
        }

        // Render with frame rate limiting (max 60fps)
        if (state.needs_render) {
            const render_now = std.time.milliTimestamp();
            if (render_now - last_render >= 16) { // ~60fps
                renderTo(state, stdout) catch {};
                state.needs_render = false;
                state.force_full_render = false;
                last_render = render_now;
            }
        }
    }
}

fn handleInput(state: *State, input_bytes: []const u8) void {
    if (input_bytes.len == 0) return;

    const slice = consumeOscReplyFromTerminal(state, input_bytes);
    if (slice.len == 0) return;

    {
        const inp = slice;

        // ==========================================================================
        // LEVEL 1: MUX-level popup blocks EVERYTHING
        // ==========================================================================
        if (state.popups.isBlocked()) {
            if (input.handlePopupInput(&state.popups, inp)) {
                // Check if this was a confirm/picker dialog for pending action
                if (state.pending_action) |action| {
                    switch (action) {
                        .adopt_choose => {
                            // Handle picker result for selecting orphaned pane
                            if (state.popups.getPickerResult()) |selected| {
                                if (selected < state.adopt_orphan_count) {
                                    state.adopt_selected_uuid = state.adopt_orphans[selected].uuid;
                                    // Now show confirm dialog
                                    state.pending_action = .adopt_confirm;
                                    state.popups.clearResults();
                                    state.popups.showConfirm("Destroy current pane?", .{}) catch {};
                                } else {
                                    state.pending_action = null;
                                }
                            } else if (state.popups.wasPickerCancelled()) {
                                state.pending_action = null;
                                state.popups.clearResults();
                            }
                        },
                        .adopt_confirm => {
                            // Handle confirm result for adopt action
                            if (state.popups.getConfirmResult()) |destroy_current| {
                                if (state.adopt_selected_uuid) |uuid| {
                                    performAdopt(state, uuid, destroy_current);
                                }
                            }
                            state.pending_action = null;
                            state.adopt_selected_uuid = null;
                            state.popups.clearResults();
                        },
                        else => {
                            // Handle other confirm dialogs (exit/detach/disown/close)
                            if (state.popups.getConfirmResult()) |confirmed| {
                                if (confirmed) {
                                    switch (action) {
                                        .exit => state.running = false,
                                        .detach => performDetach(state),
                                        .disown => performDisown(state),
                                        .close => performClose(state),
                                        else => {},
                                    }
                                } else {
                                    // User cancelled - if exit was from shell death, respawn
                                    if (action == .exit and state.exit_from_shell_death) {
                                        if (state.currentLayout().getFocusedPane()) |pane| {
                                            switch (pane.backend) {
                                                .local => {
                                                    pane.respawn() catch {
                                                        state.notifications.show("Respawn failed");
                                                    };
                                                    state.skip_dead_check = true;
                                                },
                                                .pod => {
                                                    const cwd = state.getSpawnCwd(pane);
                                                    const old_aux = state.ses_client.getPaneAux(pane.uuid) catch SesClient.PaneAuxInfo{
                                                        .created_from = null,
                                                        .focused_from = null,
                                                    };
                                                    state.ses_client.killPane(pane.uuid) catch {};
                                                    if (state.ses_client.createPane(null, cwd, null, null, null, null)) |result| {
                                                        defer state.allocator.free(result.socket_path);
                                                        var replaced = true;
                                                        pane.replaceWithPod(result.socket_path, result.uuid) catch {
                                                            replaced = false;
                                                        };
                                                        if (replaced) {
                                                            const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
                                                            const cursor = pane.getCursorPos();
                                                            const cursor_style = pane.vt.getCursorStyle();
                                                            const cursor_visible = pane.vt.isCursorVisible();
                                                            const alt_screen = pane.vt.inAltScreen();
                                                            const layout_path = getLayoutPath(state, pane) catch null;
                                                            defer if (layout_path) |path| state.allocator.free(path);
                                                            state.ses_client.updatePaneAux(
                                                                pane.uuid,
                                                                pane.floating,
                                                                pane.focused,
                                                                pane_type,
                                                                old_aux.created_from,
                                                                old_aux.focused_from,
                                                                .{ .x = cursor.x, .y = cursor.y },
                                                                cursor_style,
                                                                cursor_visible,
                                                                alt_screen,
                                                                .{ .cols = pane.width, .rows = pane.height },
                                                                pane.getPwd(),
                                                                null,
                                                                null,
                                                                layout_path,
                                                            ) catch {};
                                                            state.skip_dead_check = true;
                                                        } else {
                                                            state.notifications.show("Respawn failed");
                                                        }
                                                    } else |_| {
                                                        state.notifications.show("Respawn failed");
                                                    }
                                                },
                                            }
                                        }
                                    }
                                }
                            }
                            state.pending_action = null;
                            state.exit_from_shell_death = false;
                            state.popups.clearResults();
                        },
                    }
                } else {
                    sendPopResponse(state);
                }
            }
            state.needs_render = true;
            return;
        }

        // ==========================================================================
        // LEVEL 2: TAB-level popup - allows tab switching, blocks rest
        // ==========================================================================
        const current_tab = &state.tabs.items[state.active_tab];
        if (current_tab.popups.isBlocked()) {
            // Allow tab switching (Alt+N, Alt+P) - also support fallback keys for Alt+>/<
            if (inp.len >= 2 and inp[0] == 0x1b and inp[1] != '[' and inp[1] != 'O') {
                const cfg = &state.config;
                const is_next = inp[1] == cfg.tabs.key_next or (cfg.tabs.key_next == '>' and inp[1] == '.');
                const is_prev = inp[1] == cfg.tabs.key_prev or (cfg.tabs.key_prev == '<' and inp[1] == ',');
                if (is_next or is_prev) {
                    // Allow tab switch
                    if (handleAltKey(state, inp[1])) {
                        return;
                    }
                }
            }
            // Block everything else - handle popup input
            if (input.handlePopupInput(&current_tab.popups, inp)) {
                sendPopResponse(state);
            }
            state.needs_render = true;
            return;
        }

        var i: usize = 0;
        while (i < inp.len) {
            // Check for Alt+key (ESC followed by key)
            if (inp[i] == 0x1b and i + 1 < inp.len) {
                const next = inp[i + 1];
                // Check for CSI sequences (ESC [)
                if (next == '[' and i + 2 < inp.len) {
                    // Handle Alt+Arrow for directional navigation: ESC [ 1 ; 3 <dir>
                    if (handleAltArrow(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                    // Handle scroll keys
                    if (handleScrollKeys(state, inp[i..])) |consumed| {
                        i += consumed;
                        continue;
                    }
                }
                // Make sure it's not an actual escape sequence (like arrow keys)
                if (next != '[' and next != 'O') {
                    if (handleAltKey(state, next)) {
                        i += 2;
                        continue;
                    }
                }
            }

            // Check for Ctrl+Q to quit
            if (inp[i] == 0x11) {
                state.running = false;
                return;
            }

            // ==========================================================================
            // LEVEL 3: PANE-level popup - blocks only input to that specific pane
            // ==========================================================================
            if (state.active_floating) |idx| {
                const fpane = state.floats.items[idx];
                // Check tab ownership for tab-bound floats
                const can_interact = if (fpane.parent_tab) |parent|
                    parent == state.active_tab
                else
                    true;

                if (fpane.isVisibleOnTab(state.active_tab) and can_interact) {
                    // Check if this float pane has a blocking popup
                    if (fpane.popups.isBlocked()) {
                        if (input.handlePopupInput(&fpane.popups, inp[i..])) {
                            sendPopResponse(state);
                        }
                        state.needs_render = true;
                        return;
                    }
                    if (fpane.isScrolled()) {
                        fpane.scrollToBottom();
                        state.needs_render = true;
                    }
                    fpane.write(inp[i..]) catch {};
                } else {
                    // Can't input to tab-bound float on wrong tab, forward to tiled pane
                    if (state.currentLayout().getFocusedPane()) |pane| {
                        // Check if this pane has a blocking popup
                        if (pane.popups.isBlocked()) {
                            if (input.handlePopupInput(&pane.popups, inp[i..])) {
                                sendPopResponse(state);
                            }
                            state.needs_render = true;
                            return;
                        }
                        if (pane.isScrolled()) {
                            pane.scrollToBottom();
                            state.needs_render = true;
                        }
                        pane.write(inp[i..]) catch {};
                    }
                }
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                // Check if this pane has a blocking popup
                if (pane.popups.isBlocked()) {
                    if (input.handlePopupInput(&pane.popups, inp[i..])) {
                        sendPopResponse(state);
                    }
                    state.needs_render = true;
                    return;
                }
                if (pane.isScrolled()) {
                    pane.scrollToBottom();
                    state.needs_render = true;
                }
                pane.write(inp[i..]) catch {};
            }
            return;
        }
    }
}

fn consumeOscReplyFromTerminal(state: *State, inp: []const u8) []const u8 {
    // Only do work if we previously forwarded a query.
    if (state.osc_reply_target_uuid == null and !state.osc_reply_in_progress) return inp;

    const ESC: u8 = 0x1b;
    const BEL: u8 = 0x07;

    // Start capture only if the input begins with an OSC response.
    if (!state.osc_reply_in_progress) {
        if (inp.len < 2 or inp[0] != ESC or inp[1] != ']') return inp;
        state.osc_reply_in_progress = true;
        state.osc_reply_prev_esc = false;
        state.osc_reply_buf.clearRetainingCapacity();
    }

    var i: usize = 0;
    while (i < inp.len) : (i += 1) {
        const b = inp[i];
        state.osc_reply_buf.append(state.allocator, b) catch {
            // Drop on allocation error.
            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();
            return inp[i + 1 ..];
        };

        var done = false;
        if (b == BEL) {
            done = true;
        } else if (state.osc_reply_prev_esc and b == '\\') {
            done = true;
        }
        state.osc_reply_prev_esc = (b == ESC);

        if (state.osc_reply_buf.items.len > 64 * 1024) {
            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();
            return inp[i + 1 ..];
        }

        if (done) {
            if (state.osc_reply_target_uuid) |uuid| {
                if (state.findPaneByUuid(uuid)) |pane| {
                    pane.write(state.osc_reply_buf.items) catch {};
                }
            }

            state.osc_reply_in_progress = false;
            state.osc_reply_prev_esc = false;
            state.osc_reply_target_uuid = null;
            state.osc_reply_buf.clearRetainingCapacity();

            return inp[i + 1 ..];
        }
    }

    // Consumed everything into the pending reply buffer.
    return &[_]u8{};
}

fn handleSesMessage(state: *State, buffer: []u8) void {
    const conn = &(state.ses_client.conn orelse return);

    // Try to read a line from ses
    const line = conn.recvLine(buffer) catch return;
    if (line == null) return;

    // Parse JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line.?, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = (root.get("type") orelse return).string;

    // Handle MUX realm notification (broadcast or targeted to this mux)
    if (std.mem.eql(u8, msg_type, "notify") or std.mem.eql(u8, msg_type, "notification")) {
        if (root.get("message")) |msg_val| {
            const msg = msg_val.string;
            // Duplicate message since we'll free parsed
            const msg_copy = state.allocator.dupe(u8, msg) catch return;
            const duration_ms = if (root.get("timeout_ms")) |v| switch (v) {
                .integer => |i| i,
                else => state.notifications.default_duration_ms,
            } else state.notifications.default_duration_ms;
            state.notifications.showWithOptions(
                msg_copy,
                duration_ms,
                state.notifications.default_style,
                true,
            );
            state.needs_render = true;
        }
    }
    // Handle PANE realm notification (targeted to specific pane)
    else if (std.mem.eql(u8, msg_type, "pane_notification")) {
        const uuid_str = (root.get("uuid") orelse return).string;
        if (uuid_str.len != 32) return;

        var target_uuid: [32]u8 = undefined;
        @memcpy(&target_uuid, uuid_str[0..32]);

        const msg = (root.get("message") orelse return).string;
        const msg_copy = state.allocator.dupe(u8, msg) catch return;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;

        // Find the pane and show notification on it
        var found = false;

        // Check splits in all tabs
        for (state.tabs.items) |*tab| {
            var pane_it = tab.layout.splitIterator();
            while (pane_it.next()) |pane| {
                if (std.mem.eql(u8, &pane.*.uuid, &target_uuid)) {
                    const duration_ms = timeout_ms orelse pane.*.notifications.default_duration_ms;
                    pane.*.notifications.showWithOptions(
                        msg_copy,
                        duration_ms,
                        pane.*.notifications.default_style,
                        true,
                    );
                    found = true;
                    break;
                }
            }
            if (found) break;
        }

        // Check floats if not found
        if (!found) {
            for (state.floats.items) |pane| {
                if (std.mem.eql(u8, &pane.uuid, &target_uuid)) {
                    const duration_ms = timeout_ms orelse pane.notifications.default_duration_ms;
                    pane.notifications.showWithOptions(
                        msg_copy,
                        duration_ms,
                        pane.notifications.default_style,
                        true,
                    );
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            // Pane not found, free the copy
            state.allocator.free(msg_copy);
        }
        state.needs_render = true;
    }
    // Handle TAB realm notification (targeted to specific tab)
    else if (std.mem.eql(u8, msg_type, "tab_notification")) {
        const uuid_str = (root.get("uuid") orelse return).string;
        if (uuid_str.len < 8) return; // At least 8 char prefix

        const msg = (root.get("message") orelse return).string;
        const msg_copy = state.allocator.dupe(u8, msg) catch return;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;

        // Find the tab by UUID prefix
        var found = false;
        for (state.tabs.items) |*tab| {
            if (std.mem.startsWith(u8, &tab.uuid, uuid_str)) {
                const duration_ms = timeout_ms orelse tab.notifications.default_duration_ms;
                tab.notifications.showWithOptions(
                    msg_copy,
                    duration_ms,
                    tab.notifications.default_style,
                    true,
                );
                found = true;
                break;
            }
        }

        if (!found) {
            state.allocator.free(msg_copy);
        }
        state.needs_render = true;
    }
    // Handle pop_confirm - show confirm dialog
    else if (std.mem.eql(u8, msg_type, "pop_confirm")) {
        const msg = (root.get("message") orelse return).string;
        const target_uuid = if (root.get("target_uuid")) |v| v.string else null;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;
        const opts: pop.ConfirmOptions = .{ .timeout_ms = timeout_ms };

        // Determine scope based on target_uuid
        if (target_uuid) |uuid| {
            // Check if it matches a tab UUID
            for (state.tabs.items, 0..) |*tab, tab_idx| {
                if (std.mem.startsWith(u8, &tab.uuid, uuid)) {
                    tab.popups.showConfirmOwned(msg, opts) catch return;
                    state.pending_pop_response = true;
                    state.pending_pop_scope = .tab;
                    state.pending_pop_tab = tab_idx;
                    state.needs_render = true;
                    return;
                }
            }
            // Check if it matches a pane UUID (tiled splits)
            for (state.tabs.items) |*tab| {
                var iter = tab.layout.splits.valueIterator();
                while (iter.next()) |pane| {
                    if (std.mem.startsWith(u8, &pane.*.uuid, uuid)) {
                        pane.*.popups.showConfirmOwned(msg, opts) catch return;
                        state.pending_pop_response = true;
                        state.pending_pop_scope = .pane;
                        state.pending_pop_pane = pane.*;
                        state.needs_render = true;
                        return;
                    }
                }
            }
            // Check if it matches a float pane UUID
            for (state.floats.items) |pane| {
                if (std.mem.startsWith(u8, &pane.uuid, uuid)) {
                    pane.popups.showConfirmOwned(msg, opts) catch return;
                    state.pending_pop_response = true;
                    state.pending_pop_scope = .pane;
                    state.pending_pop_pane = pane;
                    state.needs_render = true;
                    return;
                }
            }
        }
        // Default: MUX level (blocks everything)
        state.popups.showConfirmOwned(msg, opts) catch return;
        state.pending_pop_response = true;
        state.pending_pop_scope = .mux;
        state.needs_render = true;
    }
    // Handle pop_choose - show picker dialog
    else if (std.mem.eql(u8, msg_type, "pop_choose")) {
        const msg = (root.get("message") orelse return).string;
        const items_val = root.get("items") orelse return;
        if (items_val != .array) return;
        const timeout_ms: ?i64 = if (root.get("timeout_ms")) |v| switch (v) {
            .integer => |i| i,
            else => null,
        } else null;

        // Convert JSON array to string slice
        var items_list: std.ArrayList([]const u8) = .empty;
        defer items_list.deinit(state.allocator);

        for (items_val.array.items) |item| {
            if (item == .string) {
                const duped = state.allocator.dupe(u8, item.string) catch continue;
                items_list.append(state.allocator, duped) catch {
                    state.allocator.free(duped);
                    continue;
                };
            }
        }

        if (items_list.items.len > 0) {
            state.popups.showPickerOwned(items_list.items, .{ .title = msg, .timeout_ms = timeout_ms }) catch {
                // Free items on failure
                for (items_list.items) |item| {
                    state.allocator.free(item);
                }
                return;
            };
            state.pending_pop_response = true;
            state.needs_render = true;
        }
    }
}

/// Send popup response back to ses (for CLI-triggered popups)
fn sendPopResponse(state: *State) void {
    if (!state.pending_pop_response) return;
    state.pending_pop_response = false;

    // Get the connection to ses
    const conn = &(state.ses_client.conn orelse return);

    // Get the correct PopupManager based on scope
    var popups: *pop.PopupManager = switch (state.pending_pop_scope) {
        .mux => &state.popups,
        .tab => &state.tabs.items[state.pending_pop_tab].popups,
        .pane => if (state.pending_pop_pane) |pane| &pane.popups else &state.popups,
    };

    // Check what kind of response we need to send
    var buf: [256]u8 = undefined;

    // Try to get confirm result
    if (popups.getConfirmResult()) |confirmed| {
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"confirmed\":{}}}", .{confirmed}) catch return;
        conn.sendLine(msg) catch {};
        popups.clearResults();
        return;
    }

    // Try to get picker result
    if (popups.getPickerResult()) |selected| {
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"selected\":{d}}}", .{selected}) catch return;
        conn.sendLine(msg) catch {};
        popups.clearResults();
        return;
    }

    // Picker was cancelled (result is null but wasPickerCancelled is true)
    if (popups.wasPickerCancelled()) {
        const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"cancelled\":true}}", .{}) catch return;
        conn.sendLine(msg) catch {};
        popups.clearResults();
        return;
    }

    // Confirm was cancelled (result is false - but we should have caught it above)
    // This handles edge cases
    const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"pop_response\",\"cancelled\":true}}", .{}) catch return;
    conn.sendLine(msg) catch {};
    popups.clearResults();
}

fn sendNotifyToParentMux(_: std.mem.Allocator, message: []const u8) void {
    // Get parent mux socket from environment
    const socket_path = std.posix.getenv("HEXE_MUX_SOCKET") orelse {
        _ = posix.write(posix.STDERR_FILENO, "Not inside a hexe-mux session (HEXE_MUX_SOCKET not set)\n") catch {};
        return;
    };

    // Connect to parent mux
    var client = core.ipc.Client.connect(socket_path) catch {
        _ = posix.write(posix.STDERR_FILENO, "Failed to connect to mux\n") catch {};
        return;
    };
    defer client.close();

    var conn = client.toConnection();

    // Send notify message
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{{\"type\":\"notify\",\"message\":\"{s}\"}}", .{message}) catch return;
    conn.sendLine(msg) catch {};
}

fn handleIpcConnection(state: *State, buffer: []u8) void {
    const server = &(state.ipc_server orelse return);

    // Try to accept a connection (non-blocking)
    const conn_opt = server.tryAccept() catch return;
    if (conn_opt == null) return;

    var conn = conn_opt.?;
    var keep_open = false;
    defer if (!keep_open) conn.close();

    // Read message
    const line = conn.recvLine(buffer) catch return;
    if (line == null) return;

    // Parse JSON message
    const parsed = std.json.parseFromSlice(std.json.Value, state.allocator, line.?, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;
    const msg_type = (root.get("type") orelse return).string;

    if (std.mem.eql(u8, msg_type, "notify")) {
        if (root.get("message")) |msg_val| {
            const msg = msg_val.string;
            const msg_copy = state.allocator.dupe(u8, msg) catch return;
            state.notifications.showWithOptions(
                msg_copy,
                state.notifications.default_duration_ms,
                state.notifications.default_style,
                true,
            );
            state.needs_render = true;
        }
    } else if (std.mem.eql(u8, msg_type, "float")) {
        const command_val = root.get("command") orelse {
            conn.sendLine("{\"type\":\"error\",\"message\":\"missing_command\"}") catch {};
            return;
        };
        const command = command_val.string;
        if (command.len == 0) {
            conn.sendLine("{\"type\":\"error\",\"message\":\"empty_command\"}") catch {};
            return;
        }

        const wait_for_exit = if (root.get("wait")) |v| v.bool else false;

        var result_path: ?[]u8 = null;
        defer if (result_path) |path| state.allocator.free(path);
        var env_list: std.ArrayList([]const u8) = .empty;
        defer {
            for (env_list.items) |env_line| {
                state.allocator.free(env_line);
            }
            env_list.deinit(state.allocator);
        }
        var extra_env_list: std.ArrayList([]const u8) = .empty;
        defer extra_env_list.deinit(state.allocator);
        var owned_extra_env: std.ArrayList([]u8) = .empty;
        defer {
            for (owned_extra_env.items) |owned| {
                state.allocator.free(owned);
            }
            owned_extra_env.deinit(state.allocator);
        }

        if (root.get("env_file")) |env_file_val| {
            if (env_file_val == .string and env_file_val.string.len > 0) {
                const file = std.fs.cwd().openFile(env_file_val.string, .{}) catch null;
                if (file) |env_file| {
                    defer env_file.close();
                    const content = env_file.readToEndAlloc(state.allocator, 4 * 1024 * 1024) catch null;
                    if (content) |buf| {
                        defer state.allocator.free(buf);
                        var it = std.mem.splitScalar(u8, buf, '\n');
                        while (it.next()) |entry_line| {
                            if (entry_line.len == 0) continue;
                            const owned_line = state.allocator.dupe(u8, entry_line) catch null;
                            if (owned_line) |line_copy| {
                                env_list.append(state.allocator, line_copy) catch {};
                            }
                        }
                    }
                }
                std.fs.cwd().deleteFile(env_file_val.string) catch {};
            }
        }

        if (root.get("env")) |env_val| {
            if (env_val == .array) {
                for (env_val.array.items) |entry| {
                    if (entry == .string and entry.string.len > 0) {
                        env_list.append(state.allocator, entry.string) catch {};
                    }
                }
            }
        }

        if (root.get("extra_env")) |extra_val| {
            if (extra_val == .array) {
                for (extra_val.array.items) |entry| {
                    if (entry == .string and entry.string.len > 0) {
                        extra_env_list.append(state.allocator, entry.string) catch {};
                    }
                }
            }
        }

        if (wait_for_exit) {
            if (root.get("result_file")) |rf_val| {
                if (rf_val == .string and rf_val.string.len > 0) {
                    result_path = state.allocator.dupe(u8, rf_val.string) catch null;
                }
            }
            if (result_path == null) {
                const tmp_uuid = core.ipc.generateUuid();
                result_path = std.fmt.allocPrint(state.allocator, "/tmp/hexe-float-{s}.result", .{tmp_uuid}) catch null;
            }
            if (result_path) |path| {
                const entry = std.fmt.allocPrint(state.allocator, "HEXE_FLOAT_RESULT_FILE={s}", .{path}) catch null;
                if (entry) |env_entry| {
                    owned_extra_env.append(state.allocator, env_entry) catch {};
                    extra_env_list.append(state.allocator, env_entry) catch {};
                }
            }
        }

        const env_items: ?[]const []const u8 = if (env_list.items.len > 0) env_list.items else null;
        const extra_env_items: ?[]const []const u8 = if (extra_env_list.items.len > 0) extra_env_list.items else null;

        const command_to_run = command;

        const old_uuid = state.getCurrentFocusedUuid();
        const focused_pane = if (state.active_floating) |idx| blk: {
            if (idx < state.floats.items.len) break :blk state.floats.items[idx];
            break :blk @as(?*Pane, null);
        } else state.currentLayout().getFocusedPane();
        var spawn_cwd = if (focused_pane) |pane| state.getSpawnCwd(pane) else null;
        if (root.get("cwd")) |cwd_val| {
            if (cwd_val == .string and cwd_val.string.len > 0) {
                spawn_cwd = cwd_val.string;
            }
        }

        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                state.syncPaneUnfocus(state.floats.items[idx]);
            }
        } else if (state.currentLayout().getFocusedPane()) |tiled| {
            state.syncPaneUnfocus(tiled);
        }

        const new_uuid = createAdhocFloat(state, command_to_run, spawn_cwd, env_items, extra_env_items, !wait_for_exit) catch |err| {
            const msg = std.fmt.allocPrint(state.allocator, "{{\"type\":\"error\",\"message\":\"{s}\"}}", .{@errorName(err)}) catch return;
            defer state.allocator.free(msg);
            conn.sendLine(msg) catch {};
            return;
        };

        if (state.floats.items.len > 0) {
            state.syncPaneFocus(state.floats.items[state.floats.items.len - 1], old_uuid);
        }
        state.needs_render = true;

        if (wait_for_exit) {
            if (state.floats.items.len > 0) {
                state.floats.items[state.floats.items.len - 1].capture_output = true;
            }
            const stored_path = if (result_path) |path| state.allocator.dupe(u8, path) catch null else null;
            state.pending_float_requests.put(new_uuid, .{ .fd = conn.fd, .result_path = stored_path }) catch {
                conn.sendLine("{\"type\":\"error\",\"message\":\"float_wait_failed\"}") catch {};
                return;
            };
            keep_open = true;
        } else {
            var resp_buf: [96]u8 = undefined;
            const response = std.fmt.bufPrint(&resp_buf, "{{\"type\":\"float_created\",\"uuid\":\"{s}\"}}", .{new_uuid}) catch return;
            conn.sendLine(response) catch {};
        }
    }
}

/// Handle Alt+Arrow for directional pane navigation
/// Sequence: ESC [ 1 ; 3 <A/B/C/D> (Alt+Up/Down/Right/Left)
/// Returns number of bytes consumed, or null if not an Alt+Arrow sequence
fn handleAltArrow(state: *State, inp: []const u8) ?usize {
    // Check for ESC [ 1 ; 3 <dir> pattern (6 bytes)
    if (inp.len >= 6 and inp[0] == 0x1b and inp[1] == '[' and
        inp[2] == '1' and inp[3] == ';' and inp[4] == '3')
    {
        const dir: ?layout_mod.Layout.Direction = switch (inp[5]) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => null,
        };

        if (dir) |d| {
            const old_uuid = state.getCurrentFocusedUuid();

            // Get cursor position from current pane for smarter direction targeting
            var cursor_x: u16 = 0;
            var cursor_y: u16 = 0;
            var have_cursor = false;
            if (state.active_floating) |idx| {
                const pos = state.floats.items[idx].getCursorPos();
                cursor_x = pos.x;
                cursor_y = pos.y;
                have_cursor = true;
            } else if (state.currentLayout().getFocusedPane()) |pane| {
                const pos = pane.getCursorPos();
                cursor_x = pos.x;
                cursor_y = pos.y;
                have_cursor = true;
            }

            // Unfocus current pane
            if (state.active_floating) |idx| {
                state.syncPaneUnfocus(state.floats.items[idx]);
                state.active_floating = null;
            } else if (state.currentLayout().getFocusedPane()) |old_pane| {
                state.syncPaneUnfocus(old_pane);
            }

            // Navigate in direction using cursor position for alignment
            const cursor_pos: ?layout_mod.CursorPos = if (have_cursor) .{ .x = cursor_x, .y = cursor_y } else null;
            state.currentLayout().focusDirection(d, cursor_pos);

            // Sync focus to new pane
            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }

            state.needs_render = true;
            return 6;
        }
    }

    return null;
}

/// Handle scroll-related escape sequences
/// Returns number of bytes consumed, or null if not a scroll sequence
fn handleScrollKeys(state: *State, inp: []const u8) ?usize {
    // Must start with ESC [
    if (inp.len < 3 or inp[0] != 0x1b or inp[1] != '[') return null;

    // Get focused pane
    const pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane() orelse return null;

    // If app is in alternate screen (nvim, htop, etc.), pass scroll to it
    if (pane.vt.inAltScreen()) {
        pane.write(inp) catch {};
        return inp.len;
    }

    // SGR mouse format: ESC [ < btn ; x ; y M (press) or m (release)
    if (inp.len >= 4 and inp[2] == '<') {
        // Find the 'M' or 'm' terminator
        var end: usize = 3;
        while (end < inp.len and inp[end] != 'M' and inp[end] != 'm') : (end += 1) {}
        if (end >= inp.len) return null;

        const is_release = inp[end] == 'm';

        // Parse: btn ; x ; y
        var btn: u16 = 0;
        var mouse_x: u16 = 0;
        var mouse_y: u16 = 0;
        var field: u8 = 0;
        var i: usize = 3;
        while (i < end) : (i += 1) {
            if (inp[i] == ';') {
                field += 1;
            } else if (inp[i] >= '0' and inp[i] <= '9') {
                const digit = inp[i] - '0';
                switch (field) {
                    0 => btn = btn * 10 + digit,
                    1 => mouse_x = mouse_x * 10 + digit,
                    2 => mouse_y = mouse_y * 10 + digit,
                    else => {},
                }
            }
        }

        // Convert from 1-based to 0-based coordinates
        if (mouse_x > 0) mouse_x -= 1;
        if (mouse_y > 0) mouse_y -= 1;

        // Button 64 = wheel up, 65 = wheel down
        if (btn == 64) {
            pane.scrollUp(3);
            state.needs_render = true;
            return end + 1;
        } else if (btn == 65) {
            pane.scrollDown(3);
            state.needs_render = true;
            return end + 1;
        }

        // Left click (btn 0) on release - focus pane at position
        if (btn == 0 and is_release) {
            // Check floats first (they're on top)
            var clicked_float: ?usize = null;
            for (state.floats.items, 0..) |fp, fi| {
                // Skip tab-bound floats on wrong tab
                if (fp.parent_tab) |parent| {
                    if (parent != state.active_tab) continue;
                }
                if (fp.isVisibleOnTab(state.active_tab) and mouse_x >= fp.x and mouse_x < fp.x + fp.width and
                    mouse_y >= fp.y and mouse_y < fp.y + fp.height)
                {
                    clicked_float = fi;
                    // Don't break - later floats are on top
                }
            }

            if (clicked_float) |fi| {
                const old_uuid = state.getCurrentFocusedUuid();
                state.active_floating = fi;
                state.syncPaneFocus(state.floats.items[fi], old_uuid);
                state.needs_render = true;
            } else {
                // Check splits in current tab
                const old_uuid = state.getCurrentFocusedUuid();
                state.active_floating = null;
                var pane_it = state.currentLayout().splitIterator();
                while (pane_it.next()) |p| {
                    if (mouse_x >= p.*.x and mouse_x < p.*.x + p.*.width and
                        mouse_y >= p.*.y and mouse_y < p.*.y + p.*.height)
                    {
                        state.currentLayout().focused_split_id = p.*.id;
                        state.syncPaneFocus(p.*, old_uuid);
                        state.needs_render = true;
                        break;
                    }
                }
            }
            return end + 1;
        }

        // Other mouse events - consume but don't act
        return end + 1;
    }

    // Page Up: ESC [ 5 ~
    if (inp.len >= 4 and inp[2] == '5' and inp[3] == '~') {
        pane.scrollUp(pane.height / 2);
        state.needs_render = true;
        return 4;
    }

    // Page Down: ESC [ 6 ~
    if (inp.len >= 4 and inp[2] == '6' and inp[3] == '~') {
        pane.scrollDown(pane.height / 2);
        state.needs_render = true;
        return 4;
    }

    // Shift+Page Up: ESC [ 5 ; 2 ~
    if (inp.len >= 6 and inp[2] == '5' and inp[3] == ';' and inp[4] == '2' and inp[5] == '~') {
        pane.scrollUp(pane.height);
        state.needs_render = true;
        return 6;
    }

    // Shift+Page Down: ESC [ 6 ; 2 ~
    if (inp.len >= 6 and inp[2] == '6' and inp[3] == ';' and inp[4] == '2' and inp[5] == '~') {
        pane.scrollDown(pane.height);
        state.needs_render = true;
        return 6;
    }

    // Home (scroll to top): ESC [ H or ESC [ 1 ~
    if (inp.len >= 3 and inp[2] == 'H') {
        pane.scrollToTop();
        state.needs_render = true;
        return 3;
    }
    if (inp.len >= 4 and inp[2] == '1' and inp[3] == '~') {
        pane.scrollToTop();
        state.needs_render = true;
        return 4;
    }

    // End (scroll to bottom): ESC [ F or ESC [ 4 ~
    if (inp.len >= 3 and inp[2] == 'F') {
        pane.scrollToBottom();
        state.needs_render = true;
        return 3;
    }
    if (inp.len >= 4 and inp[2] == '4' and inp[3] == '~') {
        pane.scrollToBottom();
        state.needs_render = true;
        return 4;
    }

    // Shift+Up: ESC [ 1 ; 2 A - scroll up one line
    if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';' and inp[4] == '2' and inp[5] == 'A') {
        pane.scrollUp(1);
        state.needs_render = true;
        return 6;
    }

    // Shift+Down: ESC [ 1 ; 2 B - scroll down one line
    if (inp.len >= 6 and inp[2] == '1' and inp[3] == ';' and inp[4] == '2' and inp[5] == 'B') {
        pane.scrollDown(1);
        state.needs_render = true;
        return 6;
    }

    return null;
}

/// Perform the actual detach action
fn performDetach(state: *State) void {
    // Always set detach_mode to prevent killing panes on exit
    state.detach_mode = true;

    // Serialize entire mux state
    const mux_state_json = state.serializeState() catch {
        state.notifications.showFor("Failed to serialize state", 2000);
        state.running = false;
        return;
    };
    defer state.allocator.free(mux_state_json);

    // Detach session with our UUID - panes stay grouped with full state
    state.ses_client.detachSession(state.uuid, mux_state_json) catch {
        std.debug.print("\nDetach failed - panes orphaned\n", .{});
        state.running = false;
        return;
    };
    // Print session_id (our UUID) so user can reattach
    std.debug.print("\nSession detached: {s}\nReattach with: hexe-mux --attach {s}\n", .{ state.uuid, state.uuid[0..8] });
    state.running = false;
}

/// Perform the actual disown action - orphan pane in ses and spawn new shell in same place
fn performDisown(state: *State) void {
    const pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (pane) |p| {
        switch (p.backend) {
            .pod => {
                // Get current working directory from the process before orphaning
                const cwd = state.getSpawnCwd(p);

                // Get the old pane's auxiliary info (created_from, focused_from) to inherit
                const old_aux = state.ses_client.getPaneAux(p.uuid) catch SesClient.PaneAuxInfo{
                    .created_from = null,
                    .focused_from = null,
                };

                // Orphan the current pane in ses (keeps process alive)
                state.ses_client.orphanPane(p.uuid) catch {};

                // Create a new shell via ses in the same directory and replace the pane's backend
                if (state.ses_client.createPane(null, cwd, null, null, null, null)) |result| {
                    defer state.allocator.free(result.socket_path);
                    p.replaceWithPod(result.socket_path, result.uuid) catch {
                        state.notifications.show("Disown failed: couldn't replace pane");
                        state.needs_render = true;
                        return;
                    };

                    // Sync inherited auxiliary info to the new pane
                    const pane_type: SesClient.PaneType = if (p.floating) .float else .split;
                    const cursor = p.getCursorPos();
                    const cursor_style = p.vt.getCursorStyle();
                    const cursor_visible = p.vt.isCursorVisible();
                    const alt_screen = p.vt.inAltScreen();
                    const layout_path = getLayoutPath(state, p) catch null;
                    defer if (layout_path) |path| state.allocator.free(path);
                    state.ses_client.updatePaneAux(
                        p.uuid,
                        p.floating,
                        p.focused,
                        pane_type,
                        old_aux.created_from, // Inherit creator
                        old_aux.focused_from, // Inherit last focus
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
                // Local process - just respawn
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

/// Perform the actual close action - close current float or tab
fn performClose(state: *State) void {
    if (state.active_floating) |idx| {
        const old_uuid = state.getCurrentFocusedUuid();
        const pane = state.floats.orderedRemove(idx);
        state.syncPaneUnfocus(pane);
        handleBlockingFloatCompletion(state, pane);
        // Kill in ses
        if (state.ses_client.isConnected()) {
            state.ses_client.killPane(pane.uuid) catch {};
        }
        pane.deinit();
        state.allocator.destroy(pane);
        // Focus another float or fall back to tiled pane
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
        // Close current tab, or quit if it's the last one
        if (!state.closeCurrentTab()) {
            state.running = false;
        }
    }
    state.needs_render = true;
}

/// Start the adopt orphaned pane flow
fn startAdoptFlow(state: *State) void {
    if (!state.ses_client.isConnected()) {
        state.notifications.show("Not connected to ses");
        return;
    }

    // Get list of orphaned panes
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
        // Only one orphan - skip picker, go directly to confirm
        state.adopt_selected_uuid = state.adopt_orphans[0].uuid;
        state.pending_action = .adopt_confirm;
        state.popups.showConfirm("Destroy current pane?", .{}) catch {};
    } else {
        // Multiple orphans - show picker
        // Build items list for picker (owned by popup)
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

/// Perform the actual adopt action
/// If destroy_current is true, kills the current pane; otherwise orphans it (swap)
fn performAdopt(state: *State, orphan_uuid: [32]u8, destroy_current: bool) void {
    // Adopt the selected orphan from ses
    const result = state.ses_client.adoptPane(orphan_uuid) catch {
        state.notifications.show("Failed to adopt pane");
        return;
    };

    // Get the current focused pane
    const current_pane: ?*Pane = if (state.active_floating) |idx|
        state.floats.items[idx]
    else
        state.currentLayout().getFocusedPane();

    if (current_pane) |pane| {
        if (destroy_current) {
            // Kill current pane in ses, then replace with adopted
            state.ses_client.killPane(pane.uuid) catch {};
        } else {
            // Orphan current pane (swap mode)
            state.ses_client.orphanPane(pane.uuid) catch {};
            state.notifications.show("Swapped panes (old pane orphaned)");
        }

        defer state.allocator.free(result.socket_path);

        pane.replaceWithPod(result.socket_path, result.uuid) catch {
            state.notifications.show("Failed to replace pane");
            return;
        };

        // Sync the new pane info
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

fn handleAltKey(state: *State, key: u8) bool {
    const cfg = &state.config;

    if (key == cfg.key_quit) {
        if (cfg.confirm_on_exit) {
            state.pending_action = .exit;
            state.popups.showConfirm("Exit mux?", .{}) catch {};
            state.needs_render = true;
        } else {
            state.running = false;
        }
        return true;
    }

    // Disown pane - orphans current pane in ses, spawns new shell in same place
    if (key == cfg.key_disown) {
        // Get the current pane (float or tiled)
        const current_pane: ?*Pane = if (state.active_floating) |idx|
            state.floats.items[idx]
        else
            state.currentLayout().getFocusedPane();

        // Block disown for sticky floats only
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
            performDisown(state);
        }
        return true;
    }

    // Adopt orphaned pane - interactive flow with picker and confirm
    if (key == cfg.key_adopt) {
        startAdoptFlow(state);
        return true;
    }

    // Split keys
    const split_h_key = cfg.splits.key_split_h;
    const split_v_key = cfg.splits.key_split_v;

    if (key == split_h_key) {
        const parent_uuid = state.getCurrentFocusedUuid();
        // Refresh CWD from ses for pod panes before splitting
        const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
        if (state.currentLayout().splitFocused(.horizontal, cwd) catch null) |new_pane| {
            state.syncPaneAux(new_pane, parent_uuid);
        }
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    if (key == split_v_key) {
        const parent_uuid = state.getCurrentFocusedUuid();
        // Refresh CWD from ses for pod panes before splitting
        const cwd = if (state.currentLayout().getFocusedPane()) |p| state.refreshPaneCwd(p) else null;
        if (state.currentLayout().splitFocused(.vertical, cwd) catch null) |new_pane| {
            state.syncPaneAux(new_pane, parent_uuid);
        }
        state.needs_render = true;
        state.syncStateToSes();
        return true;
    }

    // Alt+t = new tab
    if (key == cfg.tabs.key_new) {
        state.active_floating = null;
        state.createTab() catch {};
        state.needs_render = true;
        return true;
    }

    // Alt+n = next tab (also support Alt+. as fallback for Alt+>)
    if (key == cfg.tabs.key_next or (cfg.tabs.key_next == '>' and key == '.')) {
        const old_uuid = state.getCurrentFocusedUuid();
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                const fp = state.floats.items[idx];
                // Tab-bound floats lose focus when switching tabs
                if (fp.parent_tab != null) {
                    state.syncPaneUnfocus(fp);
                    state.active_floating = null;
                }
            }
        } else if (state.currentLayout().getFocusedPane()) |old_pane| {
            state.syncPaneUnfocus(old_pane);
        }
        state.nextTab();
        if (state.active_floating == null) {
            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }
        }
        state.needs_render = true;
        return true;
    }

    // Alt+p = previous tab (also support Alt+, as fallback for Alt+<)
    if (key == cfg.tabs.key_prev or (cfg.tabs.key_prev == '<' and key == ',')) {
        const old_uuid = state.getCurrentFocusedUuid();
        if (state.active_floating) |idx| {
            if (idx < state.floats.items.len) {
                const fp = state.floats.items[idx];
                // Tab-bound floats lose focus when switching tabs
                if (fp.parent_tab != null) {
                    state.syncPaneUnfocus(fp);
                    state.active_floating = null;
                }
            }
        } else if (state.currentLayout().getFocusedPane()) |old_pane| {
            state.syncPaneUnfocus(old_pane);
        }
        state.prevTab();
        if (state.active_floating == null) {
            if (state.currentLayout().getFocusedPane()) |new_pane| {
                state.syncPaneFocus(new_pane, old_uuid);
            }
        }
        state.needs_render = true;
        return true;
    }

    // Alt+x (configurable) = close current float/tab (or quit if last tab)
    if (key == cfg.tabs.key_close) {
        if (cfg.confirm_on_close) {
            state.pending_action = .close;
            const msg = if (state.active_floating != null) "Close float?" else "Close tab?";
            state.popups.showConfirm(msg, .{}) catch {};
            state.needs_render = true;
        } else {
            performClose(state);
        }
        return true;
    }

    // Alt+d = detach whole mux - keeps all panes alive in ses for --attach
    if (key == cfg.tabs.key_detach) {
        if (cfg.confirm_on_detach) {
            state.pending_action = .detach;
            state.popups.showConfirm("Detach session?", .{}) catch {};
            state.needs_render = true;
            return true;
        }
        performDetach(state);
        return true;
    }

    // Alt+space - toggle floating focus (always space)
    if (key == ' ') {
        if (state.floats.items.len > 0) {
            const old_uuid = state.getCurrentFocusedUuid();
            if (state.active_floating) |idx| {
                if (idx < state.floats.items.len) {
                    state.syncPaneUnfocus(state.floats.items[idx]);
                }
                state.active_floating = null;
                if (state.currentLayout().getFocusedPane()) |new_pane| {
                    state.syncPaneFocus(new_pane, old_uuid);
                }
            } else {
                // Find first float valid for current tab
                var first_valid: ?usize = null;
                for (state.floats.items, 0..) |fp, fi| {
                    // Skip tab-bound floats on wrong tab
                    if (fp.parent_tab) |parent| {
                        if (parent != state.active_tab) continue;
                    }
                    first_valid = fi;
                    break;
                }

                if (first_valid) |valid_idx| {
                    if (state.currentLayout().getFocusedPane()) |old_pane| {
                        state.syncPaneUnfocus(old_pane);
                    }
                    state.active_floating = valid_idx;
                    state.syncPaneFocus(state.floats.items[valid_idx], old_uuid);
                }
            }
            state.needs_render = true;
        }
        return true;
    }

    // Check for named float keys from config
    if (cfg.getFloatByKey(key)) |float_def| {
        toggleNamedFloat(state, float_def);
        state.needs_render = true;
        return true;
    }

    return false;
}

fn toggleNamedFloat(state: *State, float_def: *const core.FloatDef) void {
    // Get current directory from focused pane (for pwd floats)
    // Use refreshPaneCwd which queries ses for pod panes
    var current_dir: ?[]const u8 = null;
    if (state.currentLayout().getFocusedPane()) |focused| {
        current_dir = state.refreshPaneCwd(focused);
    }

    // Find existing float by key (and directory if pwd)
    for (state.floats.items, 0..) |pane, i| {
        if (pane.float_key == float_def.key) {
            // Tab-bound: skip if on wrong tab
            if (pane.parent_tab) |parent| {
                if (parent != state.active_tab) continue;
            }

            // For pwd floats, also check directory match
            if (float_def.pwd and pane.is_pwd) {
                // Both dirs must exist and match, or both be null
                const dirs_match = if (pane.pwd_dir) |pane_dir| blk: {
                    if (current_dir) |curr| {
                        break :blk std.mem.eql(u8, pane_dir, curr);
                    }
                    break :blk false;
                } else current_dir == null;

                if (!dirs_match) continue;
            }

            // Toggle visibility (per-tab for global floats)
            const old_uuid = state.getCurrentFocusedUuid();
            pane.toggleVisibleOnTab(state.active_tab);
            if (pane.isVisibleOnTab(state.active_tab)) {
                // Unfocus current pane (tiled or another float)
                if (state.active_floating) |afi| {
                    if (afi < state.floats.items.len) {
                        state.syncPaneUnfocus(state.floats.items[afi]);
                    }
                } else if (state.currentLayout().getFocusedPane()) |tiled| {
                    state.syncPaneUnfocus(tiled);
                }
                state.active_floating = i;
                state.syncPaneFocus(pane, old_uuid);
                // If alone mode, hide all other floats on this tab
                if (float_def.alone) {
                    for (state.floats.items) |other| {
                        if (other.float_key != float_def.key) {
                            other.setVisibleOnTab(state.active_tab, false);
                        }
                    }
                }
                // For pwd floats, hide other instances of same float (different dirs) on this tab
                if (float_def.pwd) {
                    for (state.floats.items, 0..) |other, j| {
                        if (j != i and other.float_key == float_def.key) {
                            other.setVisibleOnTab(state.active_tab, false);
                        }
                    }
                }
            } else {
                // Hiding float - focus tiled pane
                state.syncPaneUnfocus(pane);
                state.active_floating = null;
                if (state.currentLayout().getFocusedPane()) |tiled| {
                    state.syncPaneFocus(tiled, old_uuid);
                }
                // Destroy float if configured (pwd/special take priority - never destroy)
                if (float_def.destroy and !float_def.pwd and !float_def.special) {
                    if (state.ses_client.isConnected()) {
                        state.ses_client.killPane(pane.uuid) catch {};
                    }
                    pane.deinit();
                    _ = state.floats.orderedRemove(i);
                    state.syncStateToSes();
                }
            }
            return;
        }
    }

    // Not found - create new float
    // First unfocus current pane
    const old_uuid = state.getCurrentFocusedUuid();
    if (state.active_floating) |afi| {
        if (afi < state.floats.items.len) {
            state.syncPaneUnfocus(state.floats.items[afi]);
        }
    } else if (state.currentLayout().getFocusedPane()) |tiled| {
        state.syncPaneUnfocus(tiled);
    }
    createNamedFloat(state, float_def, current_dir, old_uuid) catch {};
    // Focus the new float
    if (state.floats.items.len > 0) {
        state.syncPaneFocus(state.floats.items[state.floats.items.len - 1], old_uuid);
    }

    // If alone mode, hide all other floats on this tab after creation
    if (float_def.alone) {
        for (state.floats.items) |pane| {
            if (pane.float_key != float_def.key) {
                pane.setVisibleOnTab(state.active_tab, false);
            }
        }
    }
    // For pwd floats, hide other instances of same float (different dirs) on this tab
    if (float_def.pwd) {
        const new_idx = state.floats.items.len - 1;
        for (state.floats.items, 0..) |pane, i| {
            if (i != new_idx and pane.float_key == float_def.key) {
                pane.setVisibleOnTab(state.active_tab, false);
            }
        }
    }
}

fn resizeFloatingPanes(state: *State) void {
    const avail_h = state.term_height - state.status_height;

    for (state.floats.items) |pane| {
        // Recalculate outer frame size based on stored percentages
        const outer_w: u16 = state.term_width * pane.float_width_pct / 100;
        const outer_h: u16 = avail_h * pane.float_height_pct / 100;

        // Recalculate position
        const max_x = state.term_width -| outer_w;
        const max_y = avail_h -| outer_h;
        const outer_x: u16 = max_x * pane.float_pos_x_pct / 100;
        const outer_y: u16 = max_y * pane.float_pos_y_pct / 100;

        // Calculate content area
        const pad_x: u16 = 1 + pane.float_pad_x;
        const pad_y: u16 = 1 + pane.float_pad_y;
        const content_x = outer_x + pad_x;
        const content_y = outer_y + pad_y;
        const content_w = outer_w -| (pad_x * 2);
        const content_h = outer_h -| (pad_y * 2);

        // Update pane position and size
        pane.resize(content_x, content_y, content_w, content_h) catch {};

        // Update border dimensions
        pane.border_x = outer_x;
        pane.border_y = outer_y;
        pane.border_w = outer_w;
        pane.border_h = outer_h;
    }
}

fn createAdhocFloat(
    state: *State,
    command: []const u8,
    cwd: ?[]const u8,
    env: ?[]const []const u8,
    extra_env: ?[]const []const u8,
    use_pod: bool,
) ![32]u8 {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;
    const width_pct: u16 = cfg.float_width_percent;
    const height_pct: u16 = cfg.float_height_percent;
    const pos_x_pct: u16 = 50;
    const pos_y_pct: u16 = 50;
    const pad_x_cfg: u16 = cfg.float_padding_x;
    const pad_y_cfg: u16 = cfg.float_padding_y;
    const border_color = cfg.float_color;

    const avail_h = state.term_height - state.status_height;
    const outer_w = state.term_width * width_pct / 100;
    const outer_h = avail_h * height_pct / 100;
    const max_x = state.term_width -| outer_w;
    const max_y = avail_h -| outer_h;
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
            defer state.allocator.free(result.socket_path);
            try pane.initWithPod(state.allocator, id, content_x, content_y, content_w, content_h, result.socket_path, result.uuid);
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

    if (state.config.float_style_default) |*style| {
        pane.float_style = style;
    }

    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.floats.append(state.allocator, pane);
    state.active_floating = state.floats.items.len - 1;
    state.syncPaneAux(pane, null);
    state.syncStateToSes();

    return pane.uuid;
}

fn createNamedFloat(state: *State, float_def: *const core.FloatDef, current_dir: ?[]const u8, parent_uuid: ?[32]u8) !void {
    const pane = try state.allocator.create(Pane);
    errdefer state.allocator.destroy(pane);

    const cfg = &state.config;

    // Use per-float settings or fall back to defaults
    const width_pct: u16 = float_def.width_percent orelse cfg.float_width_percent;
    const height_pct: u16 = float_def.height_percent orelse cfg.float_height_percent;
    const pos_x_pct: u16 = float_def.pos_x orelse 50; // default center
    const pos_y_pct: u16 = float_def.pos_y orelse 50; // default center
    const pad_x_cfg: u16 = float_def.padding_x orelse cfg.float_padding_x;
    const pad_y_cfg: u16 = float_def.padding_y orelse cfg.float_padding_y;
    const border_color = float_def.color orelse cfg.float_color;

    // Calculate outer frame size
    const avail_h = state.term_height - state.status_height;
    const outer_w = state.term_width * width_pct / 100;
    const outer_h = avail_h * height_pct / 100;

    // Calculate position based on pos_x/pos_y percentages
    // 0% = left/top edge, 50% = centered, 100% = right/bottom edge
    const max_x = state.term_width -| outer_w;
    const max_y = avail_h -| outer_h;
    const outer_x = max_x * pos_x_pct / 100;
    const outer_y = max_y * pos_y_pct / 100;

    // Content area: 1 cell border + configurable padding
    const pad_x: u16 = 1 + pad_x_cfg;
    const pad_y: u16 = 1 + pad_y_cfg;
    const content_x = outer_x + pad_x;
    const content_y = outer_y + pad_y;
    const content_w = outer_w -| (pad_x * 2);
    const content_h = outer_h -| (pad_y * 2);

    const id: u16 = @intCast(100 + state.floats.items.len);

    // Try to create pane via ses if available
    if (state.ses_client.isConnected()) {
        if (state.ses_client.createPane(float_def.command, current_dir, null, null, null, null)) |result| {
            defer state.allocator.free(result.socket_path);
            try pane.initWithPod(state.allocator, id, content_x, content_y, content_w, content_h, result.socket_path, result.uuid);
        } else |_| {
            // Fall back to local spawn
            try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command, current_dir, null);
        }
    } else {
        try pane.initWithCommand(state.allocator, id, content_x, content_y, content_w, content_h, float_def.command, current_dir, null);
    }

    pane.floating = true;
    pane.focused = true;
    pane.float_key = float_def.key;
    // For global floats (special or pwd), set per-tab visibility
    // For tab-bound floats, use simple visible field
    if (float_def.special or float_def.pwd) {
        pane.setVisibleOnTab(state.active_tab, true);
    } else {
        pane.visible = true;
    }
    // Store outer dimensions and style for border rendering
    pane.border_x = outer_x;
    pane.border_y = outer_y;
    pane.border_w = outer_w;
    pane.border_h = outer_h;
    pane.border_color = border_color;
    // Store percentages for resize recalculation
    pane.float_width_pct = @intCast(width_pct);
    pane.float_height_pct = @intCast(height_pct);
    pane.float_pos_x_pct = @intCast(pos_x_pct);
    pane.float_pos_y_pct = @intCast(pos_y_pct);
    pane.float_pad_x = @intCast(pad_x_cfg);
    pane.float_pad_y = @intCast(pad_y_cfg);

    // For pwd floats, store the directory and duplicate it
    if (float_def.pwd) {
        pane.is_pwd = true;
        if (current_dir) |dir| {
            pane.pwd_dir = state.allocator.dupe(u8, dir) catch null;
        }
    }

    // Set sticky flag from config
    pane.sticky = float_def.sticky;

    // For tab-bound floats (special=false and not pwd), set parent tab
    // pwd floats are always global since they're directory-specific
    if (!float_def.special and !float_def.pwd) {
        pane.parent_tab = state.active_tab;
    }

    // Store style reference (includes border characters and optional module)
    if (float_def.style) |*style| {
        pane.float_style = style;
    }

    // Configure pane notifications
    pane.configureNotificationsFromPop(&state.pop_config.pane.notification);

    try state.floats.append(state.allocator, pane);
    state.active_floating = state.floats.items.len - 1;
    state.syncPaneAux(pane, parent_uuid);
    state.syncStateToSes();
}

fn renderTo(state: *State, stdout: std.fs.File) !void {
    const renderer = &state.renderer;

    // Begin a new frame
    renderer.beginFrame();

    // Draw splits into the cell buffer
    var pane_it = state.currentLayout().splitIterator();
    while (pane_it.next()) |pane| {
        const render_state = pane.*.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.*.x, pane.*.y, pane.*.width, pane.*.height);

        const is_scrolled = pane.*.isScrolled();

        // Draw scroll indicator if pane is scrolled
        if (is_scrolled) {
            borders.drawScrollIndicator(renderer, pane.*.x, pane.*.y, pane.*.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane)
        if (pane.*.hasActiveNotification()) {
            pane.*.notifications.renderInBounds(renderer, pane.*.x, pane.*.y, pane.*.width, pane.*.height, false);
        }
    }

    // Draw split borders when there are multiple splits
    if (state.currentLayout().splitCount() > 1) {
        const content_height = state.term_height - state.status_height;
        borders.drawSplitBorders(renderer, state.currentLayout(), &state.config.splits, state.term_width, content_height);
    }

    // Draw visible floats (on top of splits)
    // Draw inactive floats first, then active one last so it's on top
    for (state.floats.items, 0..) |pane, i| {
        if (!pane.isVisibleOnTab(state.active_tab)) continue;
        if (state.active_floating == i) continue; // Skip active, draw it last
        // Skip tab-bound floats on wrong tab
        if (pane.parent_tab) |parent| {
            if (parent != state.active_tab) continue;
        }

        borders.drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, false, "", pane.border_color, pane.float_style);

        const render_state = pane.getRenderState() catch continue;
        renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);

        if (pane.isScrolled()) {
            borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
        }

        // Draw pane-local notification (PANE realm - bottom of pane)
        if (pane.hasActiveNotification()) {
            pane.notifications.renderInBounds(renderer, pane.x, pane.y, pane.width, pane.height, false);
        }
    }

    // Draw active float last so it's on top
    if (state.active_floating) |idx| {
        const pane = state.floats.items[idx];
        // Check tab ownership for tab-bound floats
        const can_render = if (pane.parent_tab) |parent|
            parent == state.active_tab
        else
            true;
        if (pane.isVisibleOnTab(state.active_tab) and can_render) {
            borders.drawFloatingBorder(renderer, pane.border_x, pane.border_y, pane.border_w, pane.border_h, true, "", pane.border_color, pane.float_style);

            if (pane.getRenderState()) |render_state| {
                renderer.drawRenderState(render_state, pane.x, pane.y, pane.width, pane.height);
            } else |_| {}

            if (pane.isScrolled()) {
                borders.drawScrollIndicator(renderer, pane.x, pane.y, pane.width);
            }

            // Draw pane-local notification (PANE realm - bottom of pane)
            if (pane.hasActiveNotification()) {
                pane.notifications.renderInBounds(renderer, pane.x, pane.y, pane.width, pane.height, false);
            }
        }
    }

    // Draw status bar if enabled
    if (state.config.tabs.status.enabled) {
        statusbar.draw(renderer, state.allocator, &state.config, state.term_width, state.term_height, state.tabs, state.active_tab, state.session_name);
    }

    // Draw TAB realm notifications (center of screen, below MUX)
    const current_tab = &state.tabs.items[state.active_tab];

    // Draw PANE-level blocking popups (for ALL panes with active popups)
    // Check all splits in current tab
    var split_iter = current_tab.layout.splits.valueIterator();
    while (split_iter.next()) |pane| {
        if (pane.*.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.carrier, pane.*.x, pane.*.y, pane.*.width, pane.*.height);
        }
    }
    // Check all floats
    for (state.floats.items) |fpane| {
        if (fpane.popups.getActivePopup()) |popup| {
            popup_render.drawInBounds(renderer, popup, &state.pop_config.carrier, fpane.x, fpane.y, fpane.width, fpane.height);
        }
    }
    if (current_tab.notifications.hasActive()) {
        // TAB notifications render in center area (distinct from MUX at top)
        current_tab.notifications.renderInBounds(renderer, 0, 0, state.term_width, state.layout_height, true);
    }

    // Draw TAB-level blocking popup (below MUX popup)
    if (current_tab.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // Draw MUX realm notifications overlay (top of screen)
    state.notifications.render(renderer, state.term_width, state.term_height);

    // Draw MUX-level blocking popup overlay (on top of everything)
    if (state.popups.getActivePopup()) |popup| {
        popup_render.draw(renderer, popup, &state.pop_config.carrier, state.term_width, state.term_height);
    }

    // End frame with differential render
    const output = try renderer.endFrame(state.force_full_render);

    // Get cursor info
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

    // Build cursor sequences
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
    //
    // IMPORTANT: terminal writes can be partial. If we don't fully flush the
    // whole frame, the outer terminal can see truncated CSI/SGR sequences,
    // which matches the observed "38;5;240m" / "[m" garbage artifacts.
    var iovecs = [_]std.posix.iovec_const{
        .{ .base = output.ptr, .len = output.len },
        .{ .base = &cursor_buf, .len = cursor_len },
    };
    try stdout.writevAll(iovecs[0..]);
}
