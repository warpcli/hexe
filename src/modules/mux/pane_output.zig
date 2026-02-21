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

            if (isOscQuery(self.osc_buf.items)) {
                self.osc_expect_response = true;
            }
            const stdout = std.fs.File.stdout();
            stdout.writeAll(self.osc_buf.items) catch {};

            self.osc_buf.clearRetainingCapacity();
        }
    }
}

fn isOscQuery(seq: []const u8) bool {
    if (seq.len < 4) return false;
    if (seq[0] != 0x1b or seq[1] != ']') return false;
    return std.mem.indexOf(u8, seq, ";?") != null;
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
