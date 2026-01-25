const std = @import("std");

/// Best-effort clipboard copy.
///
/// Strategy:
/// - Always try OSC 52 to the host terminal (works over SSH, doesn't require wl-copy/xclip).
/// - Also try native helpers when available (Wayland/X11).
pub fn copyToClipboard(allocator: std.mem.Allocator, bytes: []const u8) void {
    if (bytes.len == 0) return;

    sendOsc52(allocator, bytes);

    // Prefer Wayland.
    if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
        if (spawnClipboardWriter(allocator, &.{"wl-copy"}, bytes)) return;
    }

    // Fallback to X11.
    if (std.posix.getenv("DISPLAY") != null) {
        if (spawnClipboardWriter(allocator, &.{ "xclip", "-selection", "clipboard", "-in" }, bytes)) return;
        if (spawnClipboardWriter(allocator, &.{ "xsel", "--clipboard", "--input" }, bytes)) return;
    }
}

fn sendOsc52(allocator: std.mem.Allocator, bytes: []const u8) void {
    // OSC 52: ESC ] 52 ; c ; <base64> BEL
    // We use BEL terminator for broad compatibility.
    // To avoid pathological allocations, cap payload.
    const MAX_BYTES: usize = 128 * 1024;
    const payload = if (bytes.len > MAX_BYTES) bytes[0..MAX_BYTES] else bytes;

    const prefix = "\x1b]52;c;";
    const suffix = "\x07";

    const enc = std.base64.standard.Encoder;
    const enc_len = enc.calcSize(payload.len);

    const total = prefix.len + enc_len + suffix.len;
    var buf = allocator.alloc(u8, total) catch return;
    defer allocator.free(buf);

    @memcpy(buf[0..prefix.len], prefix);
    _ = enc.encode(buf[prefix.len .. prefix.len + enc_len], payload);
    @memcpy(buf[prefix.len + enc_len .. total], suffix);

    std.fs.File.stdout().writeAll(buf) catch {};
}

fn spawnClipboardWriter(allocator: std.mem.Allocator, argv: []const []const u8, bytes: []const u8) bool {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;

    if (child.stdin) |stdin_file| {
        stdin_file.writeAll(bytes) catch {};
        stdin_file.close();
    }
    _ = child.wait() catch {};
    return true;
}
