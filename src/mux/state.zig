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

const Pane = @import("pane.zig").Pane;

const BindKey = core.Config.BindKey;
const BindAction = core.Config.BindAction;
const FocusContext = core.Config.FocusContext;

const state_tabs = @import("state_tabs.zig");
const state_serialize = @import("state_serialize.zig");
const state_sync = @import("state_sync.zig");

pub const TabFocusKind = enum { split, float };

pub const PaneShellInfo = struct {
    cmd: ?[]u8 = null,
    cwd: ?[]u8 = null,
    status: ?i32 = null,
    duration_ms: ?u64 = null,
    jobs: ?u16 = null,

    pub fn deinit(self: *PaneShellInfo, allocator: std.mem.Allocator) void {
        if (self.cmd) |c| allocator.free(c);
        if (self.cwd) |c| allocator.free(c);
        self.* = .{};
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    config: core.Config,
    pop_config: pop.PopConfig,
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
    popups: pop.PopupManager,
    pending_action: ?PendingAction,
    exit_from_shell_death: bool,
    /// IPC client waiting for exit_intent decision (fd kept open)
    pending_exit_intent_fd: ?posix.fd_t,
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
    ipc_server: ?core.ipc.Server,
    socket_path: ?[]const u8,

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

    /// Shell-provided metadata (last command, status, duration) keyed by pane UUID.
    pane_shell: std.AutoHashMap([32]u8, PaneShellInfo),

    // Keybinding timers (hold/double-tap delayed press)
    key_timers: std.ArrayList(PendingKeyTimer),


    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16, debug: bool, log_file: ?[]const u8) !State {
        const cfg = core.Config.load(allocator);
        const pop_cfg = pop.PopConfig.load(allocator);
        const status_h: u16 = if (cfg.tabs.status.enabled) 1 else 0;
        const layout_h = height - status_h;

        const uuid = core.ipc.generateUuid();
        const session_name = core.ipc.generateSessionName();

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
            .popups = pop.PopupManager.init(allocator),
            .pending_action = null,
            .exit_from_shell_death = false,
            .pending_exit_intent_fd = null,
            .exit_intent_deadline_ms = 0,
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

            .pane_shell = std.AutoHashMap([32]u8, PaneShellInfo).init(allocator),

            .key_timers = .empty,
        };
    }

    pub fn deinit(self: *State) void {
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

        // Free shell metadata.
        {
            var it = self.pane_shell.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pane_shell.deinit();
        }

        self.key_timers.deinit(self.allocator);

        // Deinit floats.
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
        self.tab_last_floating_uuid.deinit(self.allocator);
        self.tab_last_focus_kind.deinit(self.allocator);
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

    pub fn createTab(self: *State) !void {
        return state_tabs.createTab(self);
    }

    pub fn closeCurrentTab(self: *State) bool {
        return state_tabs.closeCurrentTab(self);
    }

    pub fn adoptStickyPanes(self: *State) void {
        return state_tabs.adoptStickyPanes(self);
    }

    pub fn adoptAsFloat(self: *State, uuid: [32]u8, socket_path: []const u8, pid: posix.pid_t, float_def: *const core.FloatDef, cwd: []const u8) !void {
        return state_tabs.adoptAsFloat(self, uuid, socket_path, pid, float_def, cwd);
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

    pub fn getPaneShell(self: *const State, uuid: [32]u8) ?PaneShellInfo {
        if (self.pane_shell.get(uuid)) |v| return v;
        return null;
    }
};
