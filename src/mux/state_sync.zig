const std = @import("std");
const posix = std.posix;
const core = @import("core");

const SesClient = @import("ses_client.zig").SesClient;
const Pane = @import("pane.zig").Pane;
const helpers = @import("helpers.zig");
const TabFocusKind = @import("state.zig").TabFocusKind;

fn setLayoutFocusedSplitId(self: anytype, pane: *Pane) void {
    if (pane.floating) return;

    // Find which tab/layout owns this pane pointer and set its focused_split_id
    // to match. This keeps per-tab focus stable when switching tabs.
    for (self.tabs.items) |*tab| {
        var it = tab.layout.splits.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == pane) {
                tab.layout.focused_split_id = entry.key_ptr.*;
                return;
            }
        }
    }
}

fn rememberFloatingFocus(self: anytype, pane: *Pane) void {
    if (!pane.floating) return;
    if (self.tab_last_floating_uuid.items.len == 0) return;
    if (self.active_tab >= self.tab_last_floating_uuid.items.len) return;
    self.tab_last_floating_uuid.items[self.active_tab] = pane.uuid;
    if (self.active_tab < self.tab_last_focus_kind.items.len) {
        self.tab_last_focus_kind.items[self.active_tab] = .float;
    }
}

fn rememberSplitFocus(self: anytype, pane: *Pane) void {
    if (pane.floating) return;
    if (self.active_tab < self.tab_last_focus_kind.items.len) {
        self.tab_last_focus_kind.items[self.active_tab] = .split;
    }
}

pub fn syncStateToSes(self: anytype) void {
    if (!self.ses_client.isConnected()) return;

    const mux_state_json = self.serializeState() catch return;
    defer self.allocator.free(mux_state_json);

    self.ses_client.syncState(mux_state_json) catch {};
}

pub fn getCurrentFocusedUuid(self: anytype) ?[32]u8 {
    if (self.active_floating) |idx| {
        if (idx < self.floats.items.len) {
            return self.floats.items[idx].uuid;
        }
    }
    if (self.tabs.items.len == 0) return null;
    if (self.currentLayout().getFocusedPane()) |pane| {
        return pane.uuid;
    }
    return null;
}

pub fn syncPaneAux(self: anytype, pane: *Pane, created_from: ?[32]u8) void {
    if (!self.ses_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    if (pane.focused) {
        self.unfocusAllPanes();
        pane.focused = true;
    }

    const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
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
    ) catch {};
}

pub fn unfocusAllPanes(self: anytype) void {
    if (!self.ses_client.isConnected()) return;

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
                const layout_path = helpers.getLayoutPath(self, p.*) catch null;
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

    for (self.floats.items) |fp| {
        if (fp.uuid[0] != 0) {
            fp.focused = false;
            const cursor = fp.getCursorPos();
            const cursor_style = fp.vt.getCursorStyle();
            const cursor_visible = fp.vt.isCursorVisible();
            const alt_screen = fp.vt.inAltScreen();
            const layout_path = helpers.getLayoutPath(self, fp) catch null;
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

pub fn syncPaneFocus(self: anytype, pane: *Pane, focused_from: ?[32]u8) void {
    if (!self.ses_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    setLayoutFocusedSplitId(self, pane);
    if (pane.floating) {
        rememberFloatingFocus(self, pane);
    } else {
        rememberSplitFocus(self, pane);
    }

    self.unfocusAllPanes();

    pane.focused = true;
    const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.ses_client.updatePaneAux(
        pane.uuid,
        pane.floating,
        true,
        pane_type,
        null,
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
    ) catch {};

    self.syncStateToSes();
}

pub fn syncPaneUnfocus(self: anytype, pane: *Pane) void {
    if (!self.ses_client.isConnected()) return;
    if (pane.uuid[0] == 0) return;

    const pane_type: SesClient.PaneType = if (pane.floating) .float else .split;
    const cursor = pane.getCursorPos();
    const cursor_style = pane.vt.getCursorStyle();
    const cursor_visible = pane.vt.isCursorVisible();
    const alt_screen = pane.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, pane) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.ses_client.updatePaneAux(
        pane.uuid,
        pane.floating,
        false,
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
    ) catch {};
}

pub fn refreshPaneCwd(self: anytype, pane: *Pane) ?[]const u8 {
    switch (pane.backend) {
        .pod => {
            // Fire-and-forget: response updates pane CWD via handleSesMessage.
            self.ses_client.requestPaneCwd(pane.uuid);
        },
        .local => {},
    }
    return pane.getRealCwd();
}

pub fn getSpawnCwd(_: anytype, pane: *Pane) ?[]const u8 {
    // Use cached CWD (async requests keep it updated).
    return pane.getRealCwd();
}

pub fn syncFocusedPaneInfo(self: anytype) void {
    if (!self.ses_client.isConnected()) return;

    const pane = if (self.active_floating) |idx| blk: {
        if (idx < self.floats.items.len) break :blk self.floats.items[idx];
        break :blk @as(?*Pane, null);
    } else self.currentLayout().getFocusedPane();

    if (pane == null) return;
    const p = pane.?;
    if (p.uuid[0] == 0) return;

    _ = self.refreshPaneCwd(p);

    // Best-effort process detection.
    // - local PTY panes: query directly
    // - pod panes: fire-and-forget request (response updates cache via handleSesMessage)
    const fg_proc_local = p.getFgProcess();
    const fg_pid_local: ?i32 = if (p.getFgPid()) |pid| @intCast(pid) else null;
    if (fg_proc_local) |proc_name| {
        self.setPaneProc(p.uuid, proc_name, fg_pid_local);
    } else if (p.backend == .pod) {
        self.ses_client.requestPaneProcess(p.uuid);
    }

    const pane_type: SesClient.PaneType = if (p.floating) .float else .split;
    const cursor = p.getCursorPos();
    const cursor_style = p.vt.getCursorStyle();
    const cursor_visible = p.vt.isCursorVisible();
    const alt_screen = p.vt.inAltScreen();
    const layout_path = helpers.getLayoutPath(self, p) catch null;
    defer if (layout_path) |path| self.allocator.free(path);
    self.ses_client.updatePaneAux(
        p.uuid,
        p.floating,
        true,
        pane_type,
        null,
        null,
        .{ .x = cursor.x, .y = cursor.y },
        cursor_style,
        cursor_visible,
        alt_screen,
        .{ .cols = p.width, .rows = p.height },
        p.getRealCwd(),
        fg_proc_local,
        if (p.getFgPid()) |pid| pid else null,
        layout_path,
    ) catch {};
}

pub fn resizeFloatingPanes(self: anytype) void {
    const avail_h = self.term_height - self.status_height;

    for (self.floats.items) |pane| {
        const shadow_enabled = if (pane.float_style) |s| s.shadow_color != null else false;
        const usable_w: u16 = if (shadow_enabled) (self.term_width -| 1) else self.term_width;
        const usable_h: u16 = if (shadow_enabled and self.status_height == 0) (avail_h -| 1) else avail_h;

        const outer_w: u16 = usable_w * pane.float_width_pct / 100;
        const outer_h: u16 = usable_h * pane.float_height_pct / 100;

        const max_x = usable_w -| outer_w;
        const max_y = usable_h -| outer_h;
        const outer_x: u16 = max_x * pane.float_pos_x_pct / 100;
        const outer_y: u16 = max_y * pane.float_pos_y_pct / 100;

        const pad_x: u16 = 1 + pane.float_pad_x;
        const pad_y: u16 = 1 + pane.float_pad_y;
        const content_x = outer_x + pad_x;
        const content_y = outer_y + pad_y;
        const content_w = outer_w -| (pad_x * 2);
        const content_h = outer_h -| (pad_y * 2);

        pane.resize(content_x, content_y, content_w, content_h) catch {};

        pane.border_x = outer_x;
        pane.border_y = outer_y;
        pane.border_w = outer_w;
        pane.border_h = outer_h;
    }
}
