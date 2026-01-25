const std = @import("std");

// Symbols used by the reference design doc.
// These are single-cell in most terminals, but fonts may vary.
const HEAD: u21 = 0x25A0; // ■
const TRAIL: u21 = 0x2B1D; // ⬝
const EMPTY: u21 = ' ';

// 54 frames per cycle in the reference doc.
const WIDTH_DEFAULT: u8 = 8;
const TRAIL_LEN: u8 = 6;
// Keep the animation symmetric (same hold time on both ends).
const HOLD_DEFAULT: u8 = 9;

threadlocal var OUT_BUF: [128]u8 = undefined;
threadlocal var OUT_ANSI_BUF: [2048]u8 = undefined;

fn clampHold(hold: u8) u8 {
    if (hold > 60) return 60;
    return hold;
}

fn cycleFrames(width: u8, hold_in: u8) u32 {
    const hold: u32 = clampHold(hold_in);
    const w: u32 = width;
    return w + hold + (w - 1) + hold;
}

fn clampWidth(width: u8) u8 {
    if (width < 2) return 2;
    if (width > 32) return 32;
    return width;
}

const ScannerState = struct {
    active_position: u8,
    is_moving_forward: bool,
    is_holding: bool,
    hold_progress: u8,
};

threadlocal var IDX_BUF: [32]i8 = undefined;

fn getScannerState(frame_index: u32, width: u8, hold_in: u8) ScannerState {
    const hold: u32 = clampHold(hold_in);
    const forward_frames: u32 = width;
    const end_hold_end: u32 = forward_frames + hold;
    const backward_end: u32 = end_hold_end + width - 1;

    if (frame_index < forward_frames) {
        return .{ .active_position = @intCast(frame_index), .is_moving_forward = true, .is_holding = false, .hold_progress = 0 };
    } else if (frame_index < end_hold_end) {
        return .{ .active_position = width - 1, .is_moving_forward = true, .is_holding = true, .hold_progress = @intCast(frame_index - forward_frames) };
    } else if (frame_index < backward_end) {
        const backward_index = frame_index - end_hold_end;
        return .{ .active_position = @intCast(width - 2 - backward_index), .is_moving_forward = false, .is_holding = false, .hold_progress = 0 };
    } else {
        return .{ .active_position = 0, .is_moving_forward = false, .is_holding = true, .hold_progress = @intCast(frame_index - backward_end) };
    }
}

fn getTrailIndex(char_index: u8, state: ScannerState) i8 {
    const active = state.active_position;

    const directional_distance: i16 = if (state.is_moving_forward)
        @as(i16, active) - @as(i16, char_index)
    else
        @as(i16, char_index) - @as(i16, active);

    if (state.is_holding) {
        const adjusted = directional_distance + state.hold_progress;
        if (adjusted >= 0 and adjusted < TRAIL_LEN) {
            return @intCast(adjusted);
        }
        return -1;
    }

    if (directional_distance == 0) return 0;
    if (directional_distance > 0 and directional_distance < TRAIL_LEN) return @intCast(directional_distance);
    return -1;
}

pub fn trailIndicesWithOptions(now_ms: u64, started_at_ms: u64, width_in: u8, step_ms: u64, hold_frames: u8) []const i8 {
    const width = if (width_in == 0) WIDTH_DEFAULT else clampWidth(width_in);
    const elapsed_ms: u64 = if (now_ms > started_at_ms) now_ms - started_at_ms else 0;
    const step: u64 = if (step_ms == 0) 100 else step_ms;
    const frame: u32 = @intCast((elapsed_ms / step) % cycleFrames(width, hold_frames));
    const st = getScannerState(frame, width, hold_frames);

    var i: u8 = 0;
    while (i < width and i < IDX_BUF.len) : (i += 1) {
        IDX_BUF[i] = getTrailIndex(i, st);
    }
    return IDX_BUF[0..@min(@as(usize, width), IDX_BUF.len)];
}

pub fn render(now_ms: u64, started_at_ms: u64, width_in: u8) []const u8 {
    return renderWithOptions(now_ms, started_at_ms, width_in, 100, HOLD_DEFAULT);
}

/// Render knight-rider scanner (plain, no ANSI).
pub fn renderWithStep(now_ms: u64, started_at_ms: u64, width_in: u8, step_ms: u64) []const u8 {
    return renderWithOptions(now_ms, started_at_ms, width_in, step_ms, HOLD_DEFAULT);
}

pub fn renderWithOptions(now_ms: u64, started_at_ms: u64, width_in: u8, step_ms: u64, hold_frames: u8) []const u8 {
    const width = if (width_in == 0) WIDTH_DEFAULT else clampWidth(width_in);

    const elapsed_ms: u64 = if (now_ms > started_at_ms) now_ms - started_at_ms else 0;
    const step: u64 = if (step_ms == 0) 100 else step_ms;
    const frame: u32 = @intCast((elapsed_ms / step) % cycleFrames(width, hold_frames));
    const st = getScannerState(frame, width, hold_frames);

    var out_len: usize = 0;
    var i: u8 = 0;
    while (i < width and out_len < OUT_BUF.len) : (i += 1) {
        const idx = getTrailIndex(i, st);
        // Always show placeholders (⬝). When active, replace with blocks (■).
        const ch: u21 = if (idx >= 0) HEAD else TRAIL;
        const wrote = std.unicode.utf8Encode(ch, OUT_BUF[out_len..]) catch break;
        out_len += wrote;
    }

    return OUT_BUF[0..out_len];
}

fn ansiFg(palette: u8) []const u8 {
    // NOTE: returns a pointer to static literals.
    return switch (palette) {
        236 => "\x1b[38;5;236m",
        237 => "\x1b[38;5;237m",
        238 => "\x1b[38;5;238m",
        239 => "\x1b[38;5;239m",
        240 => "\x1b[38;5;240m",
        241 => "\x1b[38;5;241m",
        242 => "\x1b[38;5;242m",
        243 => "\x1b[38;5;243m",
        else => "\x1b[39m",
    };
}

fn appendBytes(buf: []u8, pos: *usize, bytes: []const u8) bool {
    if (pos.* + bytes.len > buf.len) return false;
    @memcpy(buf[pos.* .. pos.* + bytes.len], bytes);
    pos.* += bytes.len;
    return true;
}

fn appendCodepoint(buf: []u8, pos: *usize, cp: u21) bool {
    const wrote = std.unicode.utf8Encode(cp, buf[pos.*..]) catch return false;
    pos.* += wrote;
    return true;
}

/// ANSI-colored version for debugging via `hexe shp spinner`.
///
/// Uses a simple palette gradient (bright red head, darker trail).
pub fn renderAnsi(now_ms: u64, started_at_ms: u64, width_in: u8) []const u8 {
    return renderAnsiWithOptions(now_ms, started_at_ms, width_in, 100, HOLD_DEFAULT);
}

pub fn renderAnsiWithStep(now_ms: u64, started_at_ms: u64, width_in: u8, step_ms: u64) []const u8 {
    return renderAnsiWithOptions(now_ms, started_at_ms, width_in, step_ms, HOLD_DEFAULT);
}

pub fn renderAnsiWithOptions(now_ms: u64, started_at_ms: u64, width_in: u8, step_ms: u64, hold_frames: u8) []const u8 {
    const width = if (width_in == 0) WIDTH_DEFAULT else clampWidth(width_in);

    const elapsed_ms: u64 = if (now_ms > started_at_ms) now_ms - started_at_ms else 0;
    const step: u64 = if (step_ms == 0) 100 else step_ms;
    const frame: u32 = @intCast((elapsed_ms / step) % cycleFrames(width, hold_frames));
    const st = getScannerState(frame, width, hold_frames);

    var out_len: usize = 0;
    // Reset styles first so carriage-return redraws don't accumulate.
    if (!appendBytes(&OUT_ANSI_BUF, &out_len, "\x1b[0m")) return "";

    var i: u8 = 0;
    while (i < width) : (i += 1) {
        const idx = getTrailIndex(i, st);

        // Foreground palette gradient 243..236 (fades with distance).
        // idx=0 -> 243 (brightest)
        // idx=7+ -> 236 (dimmest)
        const pal: u8 = if (idx >= 0) blk: {
            const dist: u8 = @intCast(@min(@as(i16, 7), idx));
            break :blk @intCast(243 - dist);
        } else 0;

        if (idx >= 0) {
            // Active positions draw blocks with brighter foreground.
            if (!appendBytes(&OUT_ANSI_BUF, &out_len, ansiFg(pal))) break;
            if (!appendCodepoint(&OUT_ANSI_BUF, &out_len, HEAD)) break;
        } else {
            // Placeholders are always visible as mid-tone dots.
            if (!appendBytes(&OUT_ANSI_BUF, &out_len, ansiFg(240))) break;
            if (!appendCodepoint(&OUT_ANSI_BUF, &out_len, TRAIL)) break;
        }
    }

    _ = appendBytes(&OUT_ANSI_BUF, &out_len, "\x1b[0m");
    return OUT_ANSI_BUF[0..out_len];
}

// ─── Segment-based render (for statusbar) ──────────────────────────────────

const segment = @import("../context.zig");
const Context = segment.Context;
const Segment = segment.Segment;
const Style = @import("../../style.zig").Style;
const SpinnerDef = @import("../../config.zig").SpinnerDef;

fn getTrailIndexWithLen(char_index: u8, state: ScannerState, trail_len: u8) i8 {
    const active = state.active_position;
    const directional_distance: i16 = if (state.is_moving_forward)
        @as(i16, active) - @as(i16, char_index)
    else
        @as(i16, char_index) - @as(i16, active);

    if (state.is_holding) {
        const adjusted = directional_distance + state.hold_progress;
        if (adjusted >= 0 and adjusted < trail_len) return @intCast(adjusted);
        return -1;
    }

    if (directional_distance == 0) return 0;
    if (directional_distance > 0 and directional_distance < trail_len) return @intCast(directional_distance);
    return -1;
}

/// Render knight_rider animation as styled segments for statusbar.
pub fn renderSegments(ctx: *Context, cfg: SpinnerDef) ?[]const Segment {
    const width = clampWidth(cfg.width);
    const step_ms: u64 = if (cfg.step_ms == 0) 75 else cfg.step_ms;
    const hold: u8 = if (cfg.hold_frames == 0) 9 else cfg.hold_frames;
    const trail_len: u8 = if (cfg.trail_len == 0) 6 else cfg.trail_len;

    if (cfg.colors.len < 2) return null;

    const elapsed_ms: u64 = if (ctx.now_ms > cfg.started_at_ms) ctx.now_ms - cfg.started_at_ms else 0;
    const frame: u32 = @intCast((elapsed_ms / step_ms) % cycleFrames(width, hold));
    const st = getScannerState(frame, width, hold);

    const placeholder_color: u8 = cfg.placeholder_color orelse cfg.colors[cfg.colors.len / 2];

    ctx.segment_buffer.clearRetainingCapacity();

    var last_style: ?Style = null;
    var run_start: usize = ctx.text_buffer.items.len;

    var i: u8 = 0;
    while (i < width) : (i += 1) {
        const ti = getTrailIndexWithLen(i, st, trail_len);
        const active = ti >= 0;
        const glyph: u21 = if (active) HEAD else TRAIL;

        var s = Style{};
        if (active) {
            const dist: usize = @intCast(@min(@as(i16, @intCast(cfg.colors.len - 1)), ti));
            s.fg = .{ .palette = cfg.colors[dist] };
        } else {
            s.fg = .{ .palette = placeholder_color };
        }
        if (cfg.bg_color) |bg| {
            s.bg = .{ .palette = bg };
        }

        const same = if (last_style) |ls| std.meta.eql(ls, s) else false;
        if (!same and ctx.text_buffer.items.len > run_start and last_style != null) {
            const txt = ctx.text_buffer.items[run_start..ctx.text_buffer.items.len];
            ctx.segment_buffer.append(ctx.allocator, .{ .text = txt, .style = last_style.? }) catch return null;
            run_start = ctx.text_buffer.items.len;
        }
        last_style = s;

        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(glyph, &tmp) catch 0;
        if (n == 0) continue;
        ctx.text_buffer.appendSlice(ctx.allocator, tmp[0..n]) catch return null;
    }

    if (last_style != null and ctx.text_buffer.items.len > run_start) {
        const txt = ctx.text_buffer.items[run_start..ctx.text_buffer.items.len];
        ctx.segment_buffer.append(ctx.allocator, .{ .text = txt, .style = last_style.? }) catch return null;
    }

    return ctx.segment_buffer.items;
}
