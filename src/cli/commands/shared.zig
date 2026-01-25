const std = @import("std");

/// Parse a ` key=value` field from a line.
/// Returns the value (until next space or end of line), or null if not found.
pub fn parseField(line: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 2 > pat_buf.len) return null;
    pat_buf[0] = ' ';
    @memcpy(pat_buf[1 .. 1 + key.len], key);
    pat_buf[1 + key.len] = '=';
    const pat = pat_buf[0 .. 2 + key.len];

    const start = std.mem.indexOf(u8, line, pat) orelse return null;
    const val_start = start + pat.len;
    const rest = line[val_start..];
    const end_rel = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end_rel];
}

test "parseField basic" {
    const line = " uuid=abc123 pid=456 state=running";
    try std.testing.expectEqualSlices(u8, "abc123", parseField(line, "uuid").?);
    try std.testing.expectEqualSlices(u8, "456", parseField(line, "pid").?);
    try std.testing.expectEqualSlices(u8, "running", parseField(line, "state").?);
    try std.testing.expect(parseField(line, "missing") == null);
}
