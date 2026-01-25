const std = @import("std");

const segment = @import("context.zig");
const Style = @import("../style.zig").Style;
const animations = @import("animations/mod.zig");
const palette_ramp = @import("animations/palette_ramp.zig");

/// Show an animation while a shell command is running.
///
/// Policy:
/// - only when `ctx.shell_running` is true
/// - suppress while the focused pane is in alt screen (avoid animating during TUIs)
pub fn render(ctx: *segment.Context) ?[]const segment.Segment {
    return renderNamed(ctx, "running_anim");
}

pub fn renderNamed(ctx: *segment.Context, full_name: []const u8) ?[]const segment.Segment {
    if (!ctx.shell_running) return null;
    if (ctx.alt_screen) return null;
    const started = ctx.shell_started_at_ms orelse return null;

    var spinner: []const u8 = "knight_rider";
    var width: u8 = 8;
    var step_ms: u64 = 75;
    var hold_frames: u8 = 9;

    // Optional explicit color controls (comma-separated palette indices).
    //
    // Example:
    //   running_anim/knight_rider?colors=236,237,238,239,240,241,242,243&bg=1
    //
    // `colors` is mapped as: trail_index 0..N-1 -> colors[trail_index], clamped.
    var colors_csv: ?[]const u8 = null;
    var placeholder_pal: ?u8 = null;
    var bg_pal: ?u8 = null;

    if (std.mem.startsWith(u8, full_name, "running_anim/")) {
        const rest = full_name["running_anim/".len..];
        const qmark = std.mem.indexOfScalar(u8, rest, '?');
        const name_part = if (qmark) |q| rest[0..q] else rest;
        if (name_part.len > 0) spinner = name_part;

        if (qmark) |q| {
            const query = rest[q + 1 ..];
            var it = std.mem.tokenizeScalar(u8, query, '&');
            while (it.next()) |kv| {
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                const k = kv[0..eq];
                const v = kv[eq + 1 ..];
                if (std.mem.eql(u8, k, "width")) {
                    const wi = std.fmt.parseInt(u8, v, 10) catch continue;
                    width = wi;
                } else if (std.mem.eql(u8, k, "step")) {
                    const si = std.fmt.parseInt(u64, v, 10) catch continue;
                    step_ms = si;
                } else if (std.mem.eql(u8, k, "hold")) {
                    const hi = std.fmt.parseInt(u8, v, 10) catch continue;
                    hold_frames = hi;
                } else if (std.mem.eql(u8, k, "colors")) {
                    if (v.len > 0) colors_csv = v;
                } else if (std.mem.eql(u8, k, "placeholder")) {
                    placeholder_pal = std.fmt.parseInt(u8, v, 10) catch continue;
                } else if (std.mem.eql(u8, k, "bg")) {
                    bg_pal = std.fmt.parseInt(u8, v, 10) catch continue;
                }
            }
        }
    }

    // If colors are explicitly provided, prefer that.
    var colors_buf: [32]u8 = undefined;
    var colors_len: usize = 0;
    if (colors_csv) |csv| {
        var itc = std.mem.tokenizeScalar(u8, csv, ',');
        while (itc.next()) |tok| {
            if (colors_len >= colors_buf.len) break;
            const t = std.mem.trim(u8, tok, " \t");
            const v = std.fmt.parseInt(u8, t, 10) catch continue;
            colors_buf[colors_len] = v;
            colors_len += 1;
        }
    }

    const idxs = animations.trailIndicesWithOptions(spinner, ctx.now_ms, started, width, step_ms, hold_frames) orelse {
        // Fallback to non-colored.
        const frame = animations.renderWithOptions(spinner, ctx.now_ms, started, width, step_ms, hold_frames);
        if (frame.len == 0) return null;
        return ctx.addSegment(frame, Style{}) catch null;
    };

    // Determine ramp + placeholder.
    var ramp_slice: []const u8 = &.{};
    var placeholder_final: u8 = 0;
    if (colors_len >= 2) {
        ramp_slice = colors_buf[0..colors_len];
        placeholder_final = placeholder_pal orelse ramp_slice[ramp_slice.len / 2];
    } else {
        // Fallback: derive ramp from module style (fg -> bg) when possible.
        const fg_pal_opt: ?u8 = if (ctx.module_default_style.fg == .palette) ctx.module_default_style.fg.palette else null;
        const bg_pal_opt2: ?u8 = if (ctx.module_default_style.bg == .palette) ctx.module_default_style.bg.palette else null;
        if (fg_pal_opt == null or bg_pal_opt2 == null) {
            const frame = animations.renderWithOptions(spinner, ctx.now_ms, started, width, step_ms, hold_frames);
            if (frame.len == 0) return null;
            return ctx.addSegment(frame, Style{}) catch null;
        }
        const ramp = palette_ramp.paletteRamp(fg_pal_opt.?, bg_pal_opt2.?, 6);
        ramp_slice = ramp;
        placeholder_final = placeholder_pal orelse ramp_slice[ramp_slice.len / 2];
    }

    ctx.segment_buffer.clearRetainingCapacity();
    const start_pos = ctx.text_buffer.items.len;
    _ = start_pos;

    var last_style: ?Style = null;
    var run_start: usize = ctx.text_buffer.items.len;

    var i: usize = 0;
    while (i < idxs.len) : (i += 1) {
        const ti = idxs[i];
        const is_active = ti >= 0;
        const glyph: u21 = if (is_active) 0x25A0 else 0x2B1D;

        var s = Style{};
        if (is_active) {
            const dist: usize = @intCast(@min(@as(i16, @intCast(ramp_slice.len - 1)), ti));
            s.fg = .{ .palette = ramp_slice[dist] };
        } else {
            s.fg = .{ .palette = placeholder_final };
        }
        if (bg_pal) |bp| {
            s.bg = .{ .palette = bp };
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
