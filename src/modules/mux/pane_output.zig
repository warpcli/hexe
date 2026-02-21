const std = @import("std");

const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const pane_capture = @import("pane_capture.zig");

pub fn processOutput(self: *Pane, data: []const u8) void {
    if (self.capture_output) {
        pane_capture.appendCapturedOutput(self, data);
    }
    handleCsiQueries(self, data);
    handleDcsQueries(self, data);
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

fn handleCsiQueries(self: *Pane, data: []const u8) void {
    const ESC: u8 = 0x1b;

    for (data) |b| {
        switch (self.csi_query_state) {
            .idle => {
                if (b == ESC) self.csi_query_state = .esc;
            },
            .esc => {
                if (b == '[') {
                    self.csi_query_state = .csi;
                    self.csi_query_len = 0;
                } else {
                    self.csi_query_state = .idle;
                }
            },
            .csi => {
                if (b >= 0x40 and b <= 0x7e) {
                    handleCsiQueryFinal(self, b, self.csi_query_buf[0..self.csi_query_len]);
                    self.csi_query_state = .idle;
                    self.csi_query_len = 0;
                } else if (self.csi_query_len < self.csi_query_buf.len) {
                    self.csi_query_buf[self.csi_query_len] = b;
                    self.csi_query_len += 1;
                } else {
                    self.csi_query_state = .idle;
                    self.csi_query_len = 0;
                }
            },
        }
    }
}

fn handleCsiQueryFinal(self: *Pane, final: u8, params: []const u8) void {
    // Minimal CPR compatibility: CSI 6n -> CSI {row};{col}R
    if (final != 'n') return;

    var p = params;
    if (p.len > 0 and p[0] == '?') p = p[1..];
    if (!std.mem.eql(u8, p, "6")) return;

    const cursor = self.vt.getCursor();
    var buf: [32]u8 = undefined;
    const row: u16 = cursor.y + 1;
    const col: u16 = cursor.x + 1;
    const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ row, col }) catch return;
    self.write(resp) catch {};
}

fn handleDcsQueries(self: *Pane, data: []const u8) void {
    const ESC: u8 = 0x1b;

    for (data) |b| {
        switch (self.dcs_query_state) {
            .idle => {
                if (b == ESC) self.dcs_query_state = .esc;
            },
            .esc => {
                if (b == 'P') {
                    self.dcs_query_state = .dcs;
                    self.dcs_query_len = 0;
                } else {
                    self.dcs_query_state = .idle;
                }
            },
            .dcs => {
                if (b == ESC) {
                    self.dcs_query_state = .dcs_esc;
                } else if (self.dcs_query_len < self.dcs_query_buf.len) {
                    self.dcs_query_buf[self.dcs_query_len] = b;
                    self.dcs_query_len += 1;
                } else {
                    self.dcs_query_state = .idle;
                    self.dcs_query_len = 0;
                }
            },
            .dcs_esc => {
                if (b == '\\') {
                    handleDcsQuery(self, self.dcs_query_buf[0..self.dcs_query_len]);
                    self.dcs_query_state = .idle;
                    self.dcs_query_len = 0;
                } else if (self.dcs_query_len + 2 <= self.dcs_query_buf.len) {
                    self.dcs_query_buf[self.dcs_query_len] = ESC;
                    self.dcs_query_len += 1;
                    self.dcs_query_buf[self.dcs_query_len] = b;
                    self.dcs_query_len += 1;
                    self.dcs_query_state = .dcs;
                } else {
                    self.dcs_query_state = .idle;
                    self.dcs_query_len = 0;
                }
            },
        }
    }
}

fn handleDcsQuery(self: *Pane, payload: []const u8) void {
    // DECRQSS: DCS $ q <request> ST
    if (!std.mem.startsWith(u8, payload, "$q")) return;
    const req = payload[2..];

    // SGR request
    if (std.mem.eql(u8, req, "m")) {
        self.write("\x1bP1$r0m\x1b\\") catch {};
        return;
    }

    // DECSCUSR request (SP q)
    if (std.mem.eql(u8, req, " q")) {
        const style = self.vt.getCursorStyle();
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1bP1$r {d} q\x1b\\", .{style}) catch return;
        self.write(resp) catch {};
        return;
    }

    // DECSTBM request
    if (std.mem.eql(u8, req, "r")) {
        var buf: [64]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1bP1$r1;{d}r\x1b\\", .{self.height}) catch return;
        self.write(resp) catch {};
        return;
    }

    // Invalid/unavailable request
    self.write("\x1bP0$r\x1b\\") catch {};
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
                self.osc_expected_responses +|= 1;
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
