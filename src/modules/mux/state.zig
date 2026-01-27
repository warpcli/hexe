const std = @import("std");
const posix = std.posix;

const core = @import("core");
const pop = @import("pop");

const state_types = @import("state_types.zig");
pub const PendingAction = state_types.PendingAction;
pub const Tab = state_types.Tab;
pub const PendingFloatRequest = state_types.PendingFloatRequest;

const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;

const render = @import("render.zig");
const Renderer = render.Renderer;

const ses_client = @import("ses_client.zig");
const SesClient = ses_client.SesClient;
const OrphanedPaneInfo = ses_client.OrphanedPaneInfo;

const notification = @import("notification.zig");
const NotificationManager = notification.NotificationManager;

const OverlayManager = pop.overlay.OverlayManager;

const Pane = @import("pane.zig").Pane;

const BindKey = core.Config.BindKey;
const BindAction = core.Config.BindAction;
/// Simple focus context for timer storage (float vs split).
pub const FocusContext = enum { split, float };

const state_tabs = @import("state_tabs.zig");
const state_serialize = @import("state_serialize.zig");
const state_sync = @import("state_sync.zig");
const mouse_selection = @import("mouse_selection.zig");

pub const TabFocusKind = enum { split, float };

pub const PaneShellInfo = struct {
    cmd: ?[]u8 = null,
    cwd: ?[]u8 = null,
    status: ?i32 = null,
    duration_ms: ?u64 = null,
    jobs: ?u16 = null,

    // Running command telemetry (best-effort, sourced from shell integration).
    running: bool = false,
    started_at_ms: ?u64 = null,

    pub fn deinit(self: *PaneShellInfo, allocator: std.mem.Allocator) void {
        if (self.cmd) |c| allocator.free(c);
        if (self.cwd) |c| allocator.free(c);
        self.* = .{};
    }
};

pub const PaneProcInfo = struct {
    name: ?[]u8 = null,
    pid: ?i32 = null,

    pub fn deinit(self: *PaneProcInfo, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        self.* = .{};
    }
};

pub const State = struct {

    /// Get float definition by key from active layout
    pub fn getLayoutFloatByKey(self: *const State, key: u8) ?*const core.LayoutFloatDef {
        for (self.active_layout_floats) |*f| {
            if (f.key == key) return f;
        }
        return null;
    }
    pub const MouseDragSplitResize = struct {
        split: *layout_mod.LayoutNode.Split,
        dir: layout_mod.SplitDir,
        x: u16,
        y: u16,
        w: u16,
        h: u16,
    };

    pub const MouseDragFloatMove = struct {
        uuid: [32]u8,
        start_x: u16,
        start_y: u16,
        orig_x: u16,
        orig_y: u16,
    };

    pub const MouseDragFloatResize = struct {
        uuid: [32]u8,
        edge_mask: u8,
        start_x: u16,
        start_y: u16,
        orig_x: u16,
        orig_y: u16,
        orig_w: u16,
        orig_h: u16,
    };

    pub const MouseDrag = union(enum) {
        none,
        split_resize: MouseDragSplitResize,
        float_move: MouseDragFloatMove,
        float_resize: MouseDragFloatResize,
    };

    allocator: std.mem.Allocator,
    config: core.Config,
    pop_config: pop.PopConfig,
    ses_config: core.SesConfig,
    active_layout_floats: []const core.LayoutFloatDef,
    tabs: std.ArrayList(Tab),
    active_tab: usize,
    /// Per-tab remembered floating focus (by pane UUID).
    /// This is used to restore float focus when switching tabs.
    tab_last_floating_uuid: std.ArrayList(?[32]u8),
    /// Remembers whether the last focus in a tab was a split or a float.
    tab_last_focus_kind: std.ArrayList(TabFocusKind),
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
    overlays: OverlayManager,
    popups: pop.PopupManager,
    pending_action: ?PendingAction,
    exit_from_shell_death: bool,
    pending_exit_intent: bool,
    /// If non-zero and in the future, skip confirm_on_exit for the next last-pane death.
    exit_intent_deadline_ms: i64,
    adopt_orphans: [32]OrphanedPaneInfo = undefined,
    adopt_orphan_count: usize = 0,
    adopt_selected_uuid: ?[32]u8 = null,
    skip_dead_check: bool,
    pending_pop_response: bool,
    pending_pop_scope: pop.Scope,
    pending_pop_tab: usize,
    pending_pop_pane: ?*Pane,
    uuid: [32]u8,
    session_name: []const u8,
    session_name_owned: ?[]const u8,

    /// Monotonically increasing version counter for state sync.
    /// SES uses this to reject stale/out-of-order updates.
    state_version: u32 = 0,

    osc_reply_target_uuid: ?[32]u8,
    osc_reply_buf: std.ArrayList(u8),
    osc_reply_in_progress: bool,
    osc_reply_prev_esc: bool,

    // Stdin input can arrive split across reads. When using escape-sequence based
    // encodings (CSI-u, mouse events, etc) we must not forward partial sequences
    // into the focused pane. Keep a small tail buffer to stitch reads.
    stdin_tail: [256]u8 = undefined,
    stdin_tail_len: u8 = 0,

    pending_float_requests: std.AutoHashMap([32]u8, PendingFloatRequest),

    mouse_selection: mouse_selection.MouseSelection,
    mouse_selection_last_autoscroll_ms: i64,

    mouse_drag: MouseDrag,

    // Float title rename (inline editing)
    float_rename_uuid: ?[32]u8,
    float_rename_buf: std.ArrayList(u8),

    // Title click counter (for double-click rename)
    mouse_title_last_ms: i64,
    mouse_title_click_count: u8,
    mouse_title_last_uuid: ?[32]u8,
    mouse_title_last_x: u16,
    mouse_title_last_y: u16,

    mouse_click_last_ms: i64,
    mouse_click_count: u8,
    mouse_click_last_pane_uuid: ?[32]u8,
    mouse_click_last_x: u16,
    mouse_click_last_y: u16,

    /// Shell-provided metadata (last command, status, duration) keyed by pane UUID.
    pane_shell: std.AutoHashMap([32]u8, PaneShellInfo),

    /// Best-effort foreground process info keyed by pane UUID.
    ///
    /// For local PTY panes we can read this directly in mux.
    /// For pod panes we query it from ses (which can inspect /proc).
    pane_proc: std.AutoHashMap([32]u8, PaneProcInfo),

    // Keybinding timers (hold/double-tap delayed press)
    key_timers: std.ArrayList(PendingKeyTimer),


    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, debug: bool, log_file: ?[]const u8) !State {
        const cfg = core.Config.load(allocator);
        const pop_cfg = pop.PopConfig.load(allocator);
        const ses_cfg = core.SesConfig.load(allocator);

        // Find enabled layout's floats
        var layout_floats: []const core.LayoutFloatDef = &[_]core.LayoutFloatDef{};
        for (ses_cfg.layouts) |*layout| {
            if (layout.enabled) {
                layout_floats = layout.floats;
                break;
            }
        }

        const status_h: u16 = if (cfg.tabs.status.enabled) 1 else 0;
        const layout_h = height - status_h;

        const uuid = core.ipc.generateUuid();
        const session_name = core.ipc.generateSessionName();

        return .{
            .allocator = allocator,
            .config = cfg,
            .pop_config = pop_cfg,
            .ses_config = ses_cfg,
            .active_layout_floats = layout_floats,
            .tabs = .empty,
            .active_tab = 0,
            .tab_last_floating_uuid = .empty,
            .tab_last_focus_kind = .empty,
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
            .ses_client = SesClient.init(allocator, uuid, session_name, true, debug, log_file),
            .notifications = NotificationManager.initWithPopConfig(allocator, pop_cfg.carrier.notification),
            .overlays = OverlayManager.init(allocator),
            .popups = pop.PopupManager.init(allocator),
            .pending_action = null,
            .exit_from_shell_death = false,
            .pending_exit_intent = false,
            .exit_intent_deadline_ms = 0,
            .skip_dead_check = false,
            .pending_pop_response = false,
            .pending_pop_scope = .mux,
            .pending_pop_tab = 0,
            .pending_pop_pane = null,
            .uuid = uuid,
            .session_name = session_name,
            .session_name_owned = null,

            .osc_reply_target_uuid = null,
            .osc_reply_buf = .empty,
            .osc_reply_in_progress = false,
            .osc_reply_prev_esc = false,

            .pending_float_requests = std.AutoHashMap([32]u8, PendingFloatRequest).init(allocator),

            .mouse_selection = .{},
            .mouse_selection_last_autoscroll_ms = 0,

            .mouse_drag = .none,

            .float_rename_uuid = null,
            .float_rename_buf = .empty,

            .mouse_title_last_ms = 0,
            .mouse_title_click_count = 0,
            .mouse_title_last_uuid = null,
            .mouse_title_last_x = 0,
            .mouse_title_last_y = 0,

            .mouse_click_last_ms = 0,
            .mouse_click_count = 0,
            .mouse_click_last_pane_uuid = null,
            .mouse_click_last_x = 0,
            .mouse_click_last_y = 0,

            .pane_shell = std.AutoHashMap([32]u8, PaneShellInfo).init(allocator),

            .pane_proc = std.AutoHashMap([32]u8, PaneProcInfo).init(allocator),

            .key_timers = .empty,
        };
    }

    pub fn beginFloatRename(self: *State, pane: *Pane) void {
        const title = pane.float_title orelse return;
        if (title.len == 0) return;

        self.float_rename_uuid = pane.uuid;
        self.float_rename_buf.clearRetainingCapacity();

        const cap: usize = 64;
        const slice = title[0..@min(title.len, cap)];
        self.float_rename_buf.appendSlice(self.allocator, slice) catch {};
        self.needs_render = true;
    }

    pub fn clearFloatRename(self: *State) void {
        self.float_rename_uuid = null;
        self.float_rename_buf.clearRetainingCapacity();
        self.needs_render = true;
    }

    pub fn commitFloatRename(self: *State) void {
        const uuid = self.float_rename_uuid orelse return;
        const pane = self.findPaneByUuid(uuid) orelse {
            self.clearFloatRename();
            return;
        };

        const new_title = std.mem.trim(u8, self.float_rename_buf.items, " \t\r\n");
        if (pane.float_title) |old| {
            self.allocator.free(old);
            pane.float_title = null;
        }
        if (new_title.len > 0) {
            pane.float_title = self.allocator.dupe(u8, new_title) catch null;
        }

        // Best-effort: store title in ses memory for reattach.
        if (self.ses_client.isConnected()) {
            self.ses_client.updatePaneName(pane.uuid, pane.float_title) catch {};
        }

        self.clearFloatRename();
        self.renderer.invalidate();
        self.force_full_render = true;
        self.syncStateToSes();
    }

    pub fn deinit(self: *State) void {
        // When exiting normally (not detach), tell SES to kill our panes.
        // When detaching, panes stay alive for later reattach.
        if (!self.detach_mode and self.ses_client.isConnected()) {
            self.ses_client.shutdown(false) catch {};
        }

        // Free shell metadata.
        {
            var it = self.pane_shell.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_shell.deinit();
        }

        // Free proc metadata.
        {
            var it = self.pane_proc.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_proc.deinit();
        }

        self.key_timers.deinit(self.allocator);

        // Deinit floats.
        for (self.floats.items) |pane| {
            pane.deinit();
            self.allocator.destroy(pane);
        }
        self.floats.deinit(self.allocator);

        for (self.tabs.items) |*tab| {
            tab.deinit();
        }
        self.tabs.deinit(self.allocator);
        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
        self.config.deinit();
        var ses_cfg = self.ses_config;
        ses_cfg.deinit(self.allocator);
        self.osc_reply_buf.deinit(self.allocator);
        self.renderer.deinit();
        self.ses_client.deinit();
        self.notifications.deinit();
        self.overlays.deinit();
        self.popups.deinit();
        var req_it = self.pending_float_requests.iterator();
        while (req_it.next()) |entry| {
            if (entry.value_ptr.result_path) |path| {
                self.allocator.free(path);
            }
        }
        self.pending_float_requests.deinit();

        self.float_rename_buf.deinit(self.allocator);
        if (self.session_name_owned) |owned| {
            self.allocator.free(owned);
        }
    }

    pub const PendingKeyTimerKind = enum { delayed_press, tap_pending, hold, hold_fired, repeat_wait, repeat_active, double_tap_wait };

    pub const PendingKeyTimer = struct {
        kind: PendingKeyTimerKind,
        deadline_ms: i64,
        mods: u8,
        key: BindKey,
        action: BindAction,
        focus_ctx: FocusContext,
    };

    pub fn nextKeyTimerDeadlineMs(self: *const State, now_ms: i64) ?i64 {
        var next: ?i64 = null;
        for (self.key_timers.items) |t| {
            if (t.kind == .hold_fired) continue;
            if (t.kind == .repeat_wait or t.kind == .repeat_active) continue;
            if (t.kind == .tap_pending) continue;
            if (t.deadline_ms <= now_ms) return now_ms;
            const d = t.deadline_ms;
            if (next == null or d < next.?) next = d;
        }
        return next;
    }

    pub fn currentLayout(self: *State) *Layout {
        return state_tabs.currentLayout(self);
    }

    pub fn findPaneByUuid(self: *State, uuid: [32]u8) ?*Pane {
        return state_tabs.findPaneByUuid(self, uuid);
    }

    pub fn findPaneByPaneId(self: *State, pane_id: u16) ?*Pane {
        return state_tabs.findPaneByPaneId(self, pane_id);
    }

    pub fn createTab(self: *State) !void {
        return state_tabs.createTab(self);
    }

    pub fn closeCurrentTab(self: *State) bool {
        return state_tabs.closeCurrentTab(self);
    }

    pub fn adoptStickyPanes(self: *State) void {
        return state_tabs.adoptStickyPanes(self);
    }

    pub fn adoptAsFloat(self: *State, uuid: [32]u8, pane_id: u16, float_def: *const core.LayoutFloatDef, cwd: []const u8) !void {
        return state_tabs.adoptAsFloat(self, uuid, pane_id, float_def, cwd);
    }

    pub fn nextTab(self: *State) void {
        return state_tabs.nextTab(self);
    }

    pub fn prevTab(self: *State) void {
        return state_tabs.prevTab(self);
    }

    pub fn adoptOrphanedPane(self: *State) bool {
        return state_tabs.adoptOrphanedPane(self);
    }

    pub fn reattachSession(self: *State, session_id_prefix: []const u8) bool {
        return state_tabs.reattachSession(self, session_id_prefix);
    }

    pub fn attachOrphanedPane(self: *State, uuid_prefix: []const u8) bool {
        return state_tabs.attachOrphanedPane(self, uuid_prefix);
    }

    pub fn serializeState(self: *State) ![]const u8 {
        return state_serialize.serializeState(self);
    }

    pub fn serializeLayoutNode(self: *State, writer: anytype, node: *layout_mod.LayoutNode) !void {
        return state_serialize.serializeLayoutNode(self, writer, node);
    }

    pub fn serializePane(self: *State, writer: anytype, pane: *Pane) !void {
        return state_serialize.serializePane(self, writer, pane);
    }

    pub fn deserializeLayoutNode(self: *State, obj: std.json.ObjectMap) !*layout_mod.LayoutNode {
        return state_serialize.deserializeLayoutNode(self, obj);
    }

    pub fn syncStateToSes(self: *State) void {
        return state_sync.syncStateToSes(self);
    }

    pub fn getCurrentFocusedUuid(self: *State) ?[32]u8 {
        return state_sync.getCurrentFocusedUuid(self);
    }

    pub fn syncPaneAux(self: *State, pane: *Pane, created_from: ?[32]u8) void {
        return state_sync.syncPaneAux(self, pane, created_from);
    }

    pub fn unfocusAllPanes(self: *State) void {
        return state_sync.unfocusAllPanes(self);
    }

    pub fn syncPaneFocus(self: *State, pane: *Pane, focused_from: ?[32]u8) void {
        return state_sync.syncPaneFocus(self, pane, focused_from);
    }

    pub fn syncPaneUnfocus(self: *State, pane: *Pane) void {
        return state_sync.syncPaneUnfocus(self, pane);
    }

    pub fn refreshPaneCwd(self: *State, pane: *Pane) ?[]const u8 {
        return state_sync.refreshPaneCwd(self, pane);
    }

    pub fn getSpawnCwd(self: *State, pane: *Pane) ?[]const u8 {
        return state_sync.getSpawnCwd(self, pane);
    }

    pub fn syncFocusedPaneInfo(self: *State) void {
        return state_sync.syncFocusedPaneInfo(self);
    }

    pub fn resizeFloatingPanes(self: *State) void {
        return state_sync.resizeFloatingPanes(self);
    }

    pub fn setPaneShell(self: *State, uuid: [32]u8, cmd: ?[]const u8, cwd: ?[]const u8, status: ?i32, duration_ms: ?u64, jobs: ?u16) void {
        var entry = self.pane_shell.getPtr(uuid);
        if (entry == null) {
            self.pane_shell.put(uuid, .{}) catch return;
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            if (cmd) |c| {
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = self.allocator.dupe(u8, c) catch info.cmd;
            }
            if (cwd) |c| {
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = self.allocator.dupe(u8, c) catch info.cwd;
            }
            if (status) |s| info.status = s;
            if (duration_ms) |d| info.duration_ms = d;
            if (jobs) |j| info.jobs = j;
        }
    }

    pub fn setPaneShellRunning(self: *State, uuid: [32]u8, running: bool, started_at_ms: ?u64, cmd: ?[]const u8, cwd: ?[]const u8, jobs: ?u16) void {
        var entry = self.pane_shell.getPtr(uuid);
        if (entry == null) {
            self.pane_shell.put(uuid, .{}) catch return;
            entry = self.pane_shell.getPtr(uuid);
        }
        if (entry) |info| {
            info.running = running;
            if (started_at_ms) |t| info.started_at_ms = t;
            if (cmd) |c| {
                if (info.cmd) |old| self.allocator.free(old);
                info.cmd = self.allocator.dupe(u8, c) catch info.cmd;
            }
            if (cwd) |c| {
                if (info.cwd) |old| self.allocator.free(old);
                info.cwd = self.allocator.dupe(u8, c) catch info.cwd;
            }
            if (jobs) |j| info.jobs = j;
        }
    }

    pub fn setPaneProc(self: *State, uuid: [32]u8, name: ?[]const u8, pid: ?i32) void {
        var entry = self.pane_proc.getPtr(uuid);
        if (entry == null) {
            self.pane_proc.put(uuid, .{}) catch return;
            entry = self.pane_proc.getPtr(uuid);
        }
        if (entry) |info| {
            if (name) |n| {
                if (info.name) |old| self.allocator.free(old);
                info.name = self.allocator.dupe(u8, n) catch info.name;
            }
            if (pid) |p| info.pid = p;
        }
    }

    pub fn getPaneShell(self: *const State, uuid: [32]u8) ?PaneShellInfo {
        if (self.pane_shell.get(uuid)) |v| return v;
        return null;
    }

    pub fn getPaneProc(self: *const State, uuid: [32]u8) ?PaneProcInfo {
        if (self.pane_proc.get(uuid)) |v| return v;
        return null;
    }
};
