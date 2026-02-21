const std = @import("std");

const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const pane_capture = @import("pane_capture.zig");

pub fn processOutput(self: *Pane, data: []const u8) void {
    if (self.capture_output) {
        pane_capture.appendCapturedOutput(self, data);
    }
    forwardOsc(self, data);

    if (containsClearSeq(self.esc_tail[0..self.esc_tail_len], data)) {
        self.did_clear = true;
    }

    const take: usize = @min(@as(usize, 3), data.len);
    if (take > 0) {
        @memcpy(self.esc_tail[0..take], data[data.len - take .. data.len]);
        self.esc_tail_len = @intCast(take);
    }
}

fn forwardOsc(self: *Pane, data: []const u8) void {
    const ESC: u8 = 0x1b;
    const BEL: u8 = 0x07;

    for (data) |b| {
        if (!self.osc_in_progress) {
            if (self.osc_pending_esc) {
                self.osc_pending_esc = false;
                if (b == ']') {
                    self.osc_in_progress = true;
                    self.osc_prev_esc = false;
                    self.osc_buf.clearRetainingCapacity();
                    self.osc_buf.append(self.allocator, ESC) catch {
                        self.osc_in_progress = false;
                        continue;
                    };
                    self.osc_buf.append(self.allocator, ']') catch {
                        self.osc_in_progress = false;
                        continue;
                    };
                    continue;
                }
            }

            if (b == ESC) {
                self.osc_pending_esc = true;
            }
            continue;
        }

        self.osc_buf.append(self.allocator, b) catch {
            self.osc_in_progress = false;
            self.osc_pending_esc = false;
            self.osc_prev_esc = false;
            self.osc_buf.clearRetainingCapacity();
            continue;
        };

        var done = false;
        if (b == BEL) {
            done = true;
        } else if (self.osc_prev_esc and b == '\\') {
            done = true;
        }
        self.osc_prev_esc = (b == ESC);

        if (self.osc_buf.items.len > 64 * 1024) {
            self.osc_in_progress = false;
            self.osc_pending_esc = false;
            self.osc_prev_esc = false;
            self.osc_buf.clearRetainingCapacity();
            continue;
        }

        if (done) {
            self.osc_in_progress = false;
            self.osc_pending_esc = false;
            self.osc_prev_esc = false;

            if (shouldPassthroughOsc(self.osc_buf.items)) {
                const code = parseOscCode(self.osc_buf.items) orelse 0;
                if (code == 52) {
                    handleOsc52(self, self.osc_buf.items);
                }
                if (isOscQuery(self.osc_buf.items)) {
                    if (!handleOscQuery(self, self.osc_buf.items, code)) {
                        self.osc_expect_response = true;
                        const stdout = std.fs.File.stdout();
                        stdout.writeAll(self.osc_buf.items) catch {};
                    }
                } else {
                    const stdout = std.fs.File.stdout();
                    stdout.writeAll(self.osc_buf.items) catch {};
                }
            }

            self.osc_buf.clearRetainingCapacity();
        }
    }
}

fn handleOscQuery(self: *Pane, seq: []const u8, code: u32) bool {
    _ = seq;
    if (!(code == 10 or code == 11 or code == 12)) return false;

    const color = switch (code) {
        10 => "ffff/ffff/ffff",
        11 => "0000/0000/0000",
        12 => "ffff/ffff/ffff",
        else => "0000/0000/0000",
    };

    var buf: [48]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "\x1b]{d};rgb:{s}\x07", .{ code, color }) catch return true;
    self.write(resp) catch {};
    return true;
}

fn parseOscCode(seq: []const u8) ?u32 {
    if (seq.len < 4) return null;
    if (seq[0] != 0x1b or seq[1] != ']') return null;

    var i: usize = 2;
    var code: u32 = 0;
    var any: bool = false;
    while (i < seq.len) : (i += 1) {
        const c = seq[i];
        if (c == ';') break;
        if (c < '0' or c > '9') return null;
        any = true;
        code = code * 10 + @as(u32, c - '0');
        if (code > 10000) return null;
    }
    if (!any) return null;
    return code;
}

fn shouldPassthroughOsc(seq: []const u8) bool {
    const code = parseOscCode(seq) orelse return false;
    if (code == 0 or code == 1 or code == 2) return true;
    if (code == 7) return true;
    if (code == 52) return true;
    if (code == 4 or code == 104) return true;
    if (code >= 10 and code <= 19) return true;
    if (code >= 110 and code <= 119) return true;
    return false;
}

fn isOscQuery(seq: []const u8) bool {
    const code = parseOscCode(seq) orelse return false;
    if (!(code == 4 or code == 104 or (code >= 10 and code <= 19) or (code >= 110 and code <= 119))) return false;
    return std.mem.indexOf(u8, seq, ";?") != null;
}

fn handleOsc52(self: *Pane, seq: []const u8) void {
    const start = std.mem.indexOf(u8, seq, "\x1b]52;") orelse return;
    var i: usize = start + 5;

    const sel_end = std.mem.indexOfScalarPos(u8, seq, i, ';') orelse return;
    i = sel_end + 1;
    if (i >= seq.len) return;

    var payload = seq[i..];
    if (payload.len >= 2 and payload[payload.len - 2] == 0x1b and payload[payload.len - 1] == '\\') {
        payload = payload[0 .. payload.len - 2];
    } else if (payload.len >= 1 and payload[payload.len - 1] == 0x07) {
        payload = payload[0 .. payload.len - 1];
    }

    if (payload.len == 0) return;

    if (payload.len == 1 and payload[0] == '?') {
        respondToClipboardQuery(self, seq[start + 5 .. sel_end]);
        return;
    }

    const decoder = std.base64.standard.Decoder;
    const out_len = decoder.calcSizeForSlice(payload) catch return;
    const decoded = self.allocator.alloc(u8, out_len) catch return;
    defer self.allocator.free(decoded);
    decoder.decode(decoded, payload) catch return;

    setSystemClipboard(self.allocator, decoded);
}

fn setSystemClipboard(allocator: std.mem.Allocator, bytes: []const u8) void {
    if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
        if (spawnClipboardWriter(allocator, &.{"wl-copy"}, bytes)) return;
    }
    if (std.posix.getenv("DISPLAY") != null) {
        if (spawnClipboardWriter(allocator, &.{ "xclip", "-selection", "clipboard", "-in" }, bytes)) return;
        if (spawnClipboardWriter(allocator, &.{ "xsel", "--clipboard", "--input" }, bytes)) return;
    }
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

fn respondToClipboardQuery(self: *Pane, selection: []const u8) void {
    const content = getSystemClipboard(self.allocator) orelse return;
    defer self.allocator.free(content);

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(content.len);
    const encoded = self.allocator.alloc(u8, encoded_len) catch return;
    defer self.allocator.free(encoded);
    _ = encoder.encode(encoded, content);

    var response_buf: [8192]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, "\x1b]52;{s};{s}\x07", .{ selection, encoded }) catch return;
    self.write(response) catch {};
}

fn getSystemClipboard(allocator: std.mem.Allocator) ?[]u8 {
    if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
        if (readClipboardCommand(allocator, &.{"wl-paste"})) |content| return content;
    }
    if (std.posix.getenv("DISPLAY") != null) {
        if (readClipboardCommand(allocator, &.{ "xclip", "-selection", "clipboard", "-out" })) |content| return content;
        if (readClipboardCommand(allocator, &.{ "xsel", "--clipboard", "--output" })) |content| return content;
    }
    return null;
}

fn readClipboardCommand(allocator: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const stdout = child.stdout orelse return null;
    const content = stdout.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    _ = child.wait() catch {};

    return content;
}

fn containsClearSeq(tail: []const u8, data: []const u8) bool {
    const has_esc = std.mem.indexOfScalar(u8, data, 0x1b) != null;
    const has_ff = std.mem.indexOfScalar(u8, data, 0x0c) != null;
    const tail_has_esc = tail.len > 0 and tail[tail.len - 1] == 0x1b;
    if (!has_esc and !has_ff and !tail_has_esc) return false;

    return has_ff or
        containsSeq(tail, data, "\x1b[2J") or
        containsSeq(tail, data, "\x1b[3J") or
        containsSeq(tail, data, "\x1b[J") or
        containsSeq(tail, data, "\x1b[0J") or
        containsSeq(tail, data, "\x1b[H\x1b[2J") or
        containsSeq(tail, data, "\x1b[H\x1b[J") or
        containsSeq(tail, data, "\x1b[H\x1b[0J") or
        containsSeq(tail, data, "\x1b[1;1H\x1b[2J") or
        containsSeq(tail, data, "\x1b[1;1H\x1b[J") or
        containsSeq(tail, data, "\x1b[1;1H\x1b[0J");
}

fn containsSeq(tail: []const u8, data: []const u8, seq: []const u8) bool {
    if (std.mem.indexOf(u8, data, seq) != null) return true;
    if (tail.len == 0) return false;

    const max_k = @min(tail.len, seq.len - 1);
    var k: usize = 1;
    while (k <= max_k) : (k += 1) {
        if (std.mem.eql(u8, tail[tail.len - k .. tail.len], seq[0..k]) and
            data.len >= seq.len - k and
            std.mem.eql(u8, data[0 .. seq.len - k], seq[k..seq.len]))
        {
            return true;
        }
    }

    return false;
}
