const std = @import("std");

pub const knight_rider = @import("knight_rider.zig");
pub const palette_ramp = @import("palette_ramp.zig");

const segment = @import("../context.zig");
const Context = segment.Context;
const Segment = segment.Segment;
const SpinnerDef = @import("../../config.zig").SpinnerDef;

/// Render an animation frame as UTF-8 text.
///
/// The output is intended to be embedded in a single statusline segment.
pub fn render(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8) []const u8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.render(now_ms, started_at_ms, width);
    }
    // Unknown -> empty.
    return "";
}

pub fn renderWithStep(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8, step_ms: u64) []const u8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.renderWithStep(now_ms, started_at_ms, width, step_ms);
    }
    return "";
}

pub fn renderWithOptions(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8, step_ms: u64, hold_frames: u8) []const u8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.renderWithOptions(now_ms, started_at_ms, width, step_ms, hold_frames);
    }
    return "";
}

/// Render an animation frame with ANSI styling.
///
/// Intended for `hexe shp spinner --loop` debugging.
pub fn renderAnsi(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8) []const u8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.renderAnsi(now_ms, started_at_ms, width);
    }
    return "";
}

pub fn renderAnsiWithStep(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8, step_ms: u64) []const u8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.renderAnsiWithStep(now_ms, started_at_ms, width, step_ms);
    }
    return "";
}

pub fn renderAnsiWithOptions(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8, step_ms: u64, hold_frames: u8) []const u8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.renderAnsiWithOptions(now_ms, started_at_ms, width, step_ms, hold_frames);
    }
    return "";
}

pub fn trailIndicesWithOptions(name: []const u8, now_ms: u64, started_at_ms: u64, width: u8, step_ms: u64, hold_frames: u8) ?[]const i8 {
    if (std.mem.eql(u8, name, "knight_rider")) {
        return knight_rider.trailIndicesWithOptions(now_ms, started_at_ms, width, step_ms, hold_frames);
    }
    return null;
}

/// Render an animation as styled segments (for statusbar).
pub fn renderSegments(ctx: *Context, cfg: SpinnerDef) ?[]const Segment {
    if (std.mem.eql(u8, cfg.kind, "knight_rider")) {
        return knight_rider.renderSegments(ctx, cfg);
    }
    return null;
}
