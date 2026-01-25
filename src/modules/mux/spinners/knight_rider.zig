const std = @import("std");
const core = @import("core");
const shp = @import("shp");

const HEAD: u21 = 0x25A0; // ■
const DOT: u21 = 0x2B1D; // ⬝

fn clampWidth(width: u8) u8 {
    if (width < 2) return 2;
    if (width > 32) return 32;
    return width;
}

fn clampHold(hold: u8) u8 {
    return @min(hold, 60);
}

fn cycleFrames(width: u8, hold_in: u8) u32 {
    const hold: u32 = clampHold(hold_in);
    const w: u32 = width;
    return w + hold + (w - 1) + hold;
}

const ScannerState = struct {
    active_position: u8,
    is_moving_forward: bool,
    is_holding: bool,
    hold_progress: u8,
};

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

fn getTrailIndex(char_index: u8, state: ScannerState, trail_len: u8) i8 {
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

pub fn render(ctx: *shp.Context, cfg: core.SpinnerDef) ?[]const shp.Segment {
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

    var last_style: ?shp.Style = null;
    var run_start: usize = ctx.text_buffer.items.len;

    var i: u8 = 0;
    while (i < width) : (i += 1) {
        const ti = getTrailIndex(i, st, trail_len);
        const active = ti >= 0;
        const glyph: u21 = if (active) HEAD else DOT;

        var s = shp.Style{};
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
