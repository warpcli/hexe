const std = @import("std");
const ghostty = @import("ghostty-vt");

const Pane = @import("pane.zig").Pane;
const render = @import("render.zig");
const Renderer = render.Renderer;

/// Pane-local mouse coordinate (viewport coordinate space).
pub const Pos = struct {
    x: u16 = 0,
    y: u16 = 0,
};

/// Terminal-buffer coordinate space ("screen" tag in ghostty).
pub const BufPos = struct {
    x: u16 = 0,
    y: u32 = 0,
};

pub const Range = struct {
    a: Pos,
    b: Pos,
};

pub const BufRange = struct {
    a: BufPos,
    b: BufPos,
};

pub const EdgeScroll = enum { none, up, down };

/// Pane-local selection state driven by mux mouse events.
///
/// Internally we store Y positions in terminal "screen" coordinates so the
/// selection stays attached to the same buffer lines when the viewport scrolls.
pub const MouseSelection = struct {
    tab: ?usize = null,
    pane_uuid: ?[32]u8 = null,

    active: bool = false,
    dragging: bool = false,

    last_local: Pos = .{},
    edge_scroll: EdgeScroll = .none,

    anchor: BufPos = .{},
    cursor: BufPos = .{},

    has_range: bool = false,
    last_range: BufRange = .{ .a = .{}, .b = .{} },

    pub fn clear(self: *MouseSelection) void {
        self.* = .{};
    }

    pub fn begin(self: *MouseSelection, tab_idx: usize, pane_uuid: [32]u8, pane: *Pane, local_x: u16, local_y: u16) void {
        const viewport_top = getViewportTopScreenY(pane);
        self.tab = tab_idx;
        self.pane_uuid = pane_uuid;
        self.active = true;
        self.dragging = false;
        self.last_local = .{ .x = local_x, .y = local_y };
        self.edge_scroll = edgeFromLocalY(local_y, pane.height);
        self.anchor = .{ .x = local_x, .y = viewport_top + local_y };
        self.cursor = self.anchor;
        self.has_range = false;
    }

    pub fn update(self: *MouseSelection, pane: *Pane, local_x: u16, local_y: u16) void {
        if (!self.active) return;
        const viewport_top = getViewportTopScreenY(pane);
        const next: BufPos = .{ .x = local_x, .y = viewport_top + local_y };
        self.last_local = .{ .x = local_x, .y = local_y };
        self.edge_scroll = edgeFromLocalY(local_y, pane.height);
        if (self.cursor.x != next.x or self.cursor.y != next.y) {
            self.dragging = true;
        }
        self.cursor = next;
    }

    pub fn finish(self: *MouseSelection) void {
        if (!self.active) return;
        self.active = false;
        self.edge_scroll = .none;
        if (self.dragging) {
            self.has_range = true;
            self.last_range = .{ .a = self.anchor, .b = self.cursor };
        } else {
            self.has_range = false;
        }
    }

    pub fn bufRangeForPane(self: *const MouseSelection, tab_idx: usize, pane: *Pane) ?BufRange {
        if (self.tab == null or self.pane_uuid == null) return null;
        if (self.tab.? != tab_idx) return null;
        if (!std.mem.eql(u8, &self.pane_uuid.?, &pane.uuid)) return null;

        if (self.active) return .{ .a = self.anchor, .b = self.cursor };
        if (self.has_range) return self.last_range;
        return null;
    }

    /// Convert selection to pane-local viewport coordinates for overlay.
    /// Returns null if the selection isn't currently visible in this viewport.
    pub fn rangeForPane(self: *const MouseSelection, tab_idx: usize, pane: *Pane) ?Range {
        const br = self.bufRangeForPane(tab_idx, pane) orelse return null;

        const viewport_top = getViewportTopScreenY(pane);
        const viewport_bottom: u32 = viewport_top + @as(u32, @intCast(@max(pane.height, 1) - 1));
        const norm = normalizeBufRange(br);

        // Not visible at all.
        if (norm.end.y < viewport_top or norm.start.y > viewport_bottom) return null;

        return .{
            .a = bufToLocalClipped(norm.start, viewport_top, pane.width, pane.height, true),
            .b = bufToLocalClipped(norm.end, viewport_top, pane.width, pane.height, false),
        };
    }
};

fn clampToPane(x: u16, y: u16, w: u16, h: u16) Pos {
    const cx: u16 = if (w == 0) 0 else @min(x, w - 1);
    const cy: u16 = if (h == 0) 0 else @min(y, h - 1);
    return .{ .x = cx, .y = cy };
}

fn normalizeRange(range: Range) struct { start: Pos, end: Pos } {
    const a = range.a;
    const b = range.b;
    if (a.y < b.y or (a.y == b.y and a.x <= b.x)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

fn normalizeBufRange(range: BufRange) struct { start: BufPos, end: BufPos } {
    const a = range.a;
    const b = range.b;
    if (a.y < b.y or (a.y == b.y and a.x <= b.x)) {
        return .{ .start = a, .end = b };
    }
    return .{ .start = b, .end = a };
}

pub fn clampLocalToPane(local_x: u16, local_y: u16, pane_w: u16, pane_h: u16) Pos {
    return clampToPane(local_x, local_y, pane_w, pane_h);
}

pub fn applyOverlay(renderer: *Renderer, pane_x: u16, pane_y: u16, pane_w: u16, pane_h: u16, range: Range) void {
    if (pane_w == 0 or pane_h == 0) return;
    const a = clampToPane(range.a.x, range.a.y, pane_w, pane_h);
    const b = clampToPane(range.b.x, range.b.y, pane_w, pane_h);
    const norm = normalizeRange(.{ .a = a, .b = b });

    var y: u16 = norm.start.y;
    while (y <= norm.end.y) : (y += 1) {
        const start_x: u16 = if (y == norm.start.y) norm.start.x else 0;
        const end_x: u16 = if (y == norm.end.y) norm.end.x else (pane_w - 1);
        var x: u16 = start_x;
        while (x <= end_x) : (x += 1) {
            renderer.invertCell(pane_x + x, pane_y + y);
        }
    }
}

/// Extract selection text from the full terminal buffer (supports scrollback).
///
/// This uses ghostty's `Screen.selectionString` to correctly unwrap soft wraps
/// and handle scrollback/history.
pub fn extractText(allocator: std.mem.Allocator, pane: *Pane, range: BufRange) ![]u8 {
    const screen = pane.vt.terminal.screens.active;
    const pages = &screen.pages;
    const norm = normalizeBufRange(range);

    const start_pin = pages.pin(.{ .screen = .{ .x = @intCast(norm.start.x), .y = norm.start.y } }) orelse return allocator.dupe(u8, "");
    const end_pin = pages.pin(.{ .screen = .{ .x = @intCast(norm.end.x), .y = norm.end.y } }) orelse return allocator.dupe(u8, "");

    const sel = ghostty.Selection.init(start_pin, end_pin, false);
    const text_z = try screen.selectionString(allocator, .{ .sel = sel, .trim = true });
    defer allocator.free(text_z);

    const slice = std.mem.sliceTo(text_z, 0);
    return dupeTrimBlankLines(allocator, slice);
}

fn getViewportTopScreenY(pane: *Pane) u32 {
    const screen = pane.vt.terminal.screens.active;
    const pin = screen.pages.getTopLeft(.viewport);
    const pt = screen.pages.pointFromPin(.screen, pin) orelse return 0;
    return pt.screen.y;
}

fn edgeFromLocalY(local_y: u16, pane_h: u16) EdgeScroll {
    if (pane_h == 0) return .none;
    // Start scrolling when cursor is in the top/bottom margin.
    const margin: u16 = 1;
    if (local_y <= margin) return .up;
    if (local_y + margin >= pane_h - 1) return .down;
    return .none;
}

fn isBlankLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len == 0;
}

fn dupeTrimBlankLines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return allocator.dupe(u8, "");

    // Find first non-blank line.
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..line_end];
        if (!isBlankLine(line)) {
            start = i;
            break;
        }
        if (line_end == text.len) return allocator.dupe(u8, "");
        i = line_end + 1;
    }

    // Find last non-blank line.
    var end: usize = text.len;
    var j: usize = text.len;
    while (j > start) {
        // Identify the start/end of the previous line.
        const nl = std.mem.lastIndexOfScalar(u8, text[0..j], '\n');
        const line_start: usize = if (nl) |p| p + 1 else 0;
        const line_end: usize = j;
        const line = text[line_start..line_end];
        if (!isBlankLine(line)) {
            end = line_end;
            break;
        }
        if (nl) |p| {
            if (p == 0) break;
            j = p;
        } else {
            break;
        }
    }

    if (start >= end) return allocator.dupe(u8, "");
    return allocator.dupe(u8, text[start..end]);
}

fn bufToLocalClipped(p: BufPos, viewport_top: u32, pane_w: u16, pane_h: u16, is_start: bool) Pos {
    if (pane_w == 0 or pane_h == 0) return .{};
    const viewport_bottom: u32 = viewport_top + @as(u32, @intCast(pane_h - 1));

    // Clip vertically to the viewport. For clipped ends we stretch to full
    // line so the visible portion is highlighted.
    if (p.y < viewport_top) {
        return .{ .x = if (is_start) 0 else pane_w - 1, .y = 0 };
    }
    if (p.y > viewport_bottom) {
        return .{ .x = if (is_start) 0 else pane_w - 1, .y = pane_h - 1 };
    }

    const local_y: u16 = @intCast(p.y - viewport_top);
    const local_x: u16 = if (p.x >= pane_w) pane_w - 1 else p.x;
    return .{ .x = local_x, .y = local_y };
}
