const std = @import("std");

const segment = @import("../segment.zig");
const Style = @import("../style.zig").Style;

const WORDS = [_][]const u8{
    "moonwalking",
    "beaming",
    "pursuing",
    "zigzagging",
    "drifting",
    "gliding",
    "wandering",
    "roaming",
    "spiraling",
    "hovering",
    "flickering",
    "shimmering",
    "echoing",
    "pulsing",
    "cascading",
    "orbiting",
    "meandering",
    "phasing",
    "blinking",
    "streaking",
    "vaulting",
    "slipping",
    "skimming",
    "floating",
    "rippling",
    "oscillating",
    "darting",
    "sliding",
    "rolling",
    "weaving",
    "flowing",
    "sweeping",
    "bursting",
    "charging",
    "flaring",
    "bouncing",
    "skipping",
    "tracing",
    "looping",
    "tilting",
    "tumbling",
    "glimmering",
    "warping",
    "cruising",
    "ghosting",
    "morphing",
    "phantoming",
    "bobbing",
    "lunging",
    "stalking",
    "creeping",
    "prowling",
    "surging",
    "flashing",
    "glancing",
    "sidestepping",
    "sidling",
    "zigging",
    "zagging",
    "pivoting",
    "arcing",
    "swooping",
    "dipping",
    "fluttering",
    "skittering",
    "scampering",
    "shuffling",
    "peeking",
    "peering",
    "flicking",
    "twisting",
    "coiling",
    "uncoiling",
    "threading",
    "streaming",
    "jetting",
    "blooming",
    "glowing",
    "radiating",
    "scanning",
    "tracking",
    "homing",
    "locking",
    "unlocking",
    "syncing",
    "desyncing",
    "buffering",
    "hopping",
    "bounding",
};

pub fn render(ctx: *segment.Context) ?[]const segment.Segment {
    // Change word at a human-friendly cadence.
    // Use ctx.now_ms when available; fall back to wall clock for robustness.
    const now_ms: u64 = if (ctx.now_ms != 0) ctx.now_ms else @intCast(std.time.milliTimestamp());
    const tick: u64 = now_ms / 700;

    // Build a stable input blob: tick + cwd.
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], tick, .little);
    const cwd_bytes = ctx.cwd;
    const h1 = std.hash.Wyhash.hash(0, buf[0..8]);
    const h2 = std.hash.Wyhash.hash(h1, cwd_bytes);
    const idx: usize = @intCast(h2 % WORDS.len);
    return ctx.addSegment(WORDS[idx], Style{}) catch null;
}
