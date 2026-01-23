const std = @import("std");
const core = @import("core");
const shp = @import("shp");

pub const knight_rider = @import("knight_rider.zig");

/// Render a spinner into the provided shp context buffers.
///
/// Returns a slice of segments backed by `ctx.segment_buffer` and
/// `ctx.text_buffer`.
pub fn render(ctx: *shp.Context, cfg: core.SpinnerDef) ?[]const shp.Segment {
    if (std.mem.eql(u8, cfg.kind, "knight_rider")) {
        return knight_rider.render(ctx, cfg);
    }
    return null;
}
