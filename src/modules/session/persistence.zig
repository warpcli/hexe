const std = @import("std");
const core = @import("core");
const ipc = core.ipc;
const txlog = @import("txlog.zig");

/// Transaction log file handle + path bookkeeping.
pub const Persistence = struct {
    allocator: std.mem.Allocator,
    txlog: txlog.TxLog,
    txlog_path: []const u8, // Owned, must be freed in deinit()
    txlog_path_is_fallback: bool, // Track if using string literal fallback

    pub fn init(allocator: std.mem.Allocator) Persistence {
        const fallback_path = "/tmp/hexe-ses.txlog";
        const path = ipc.getTxLogPath(allocator) catch fallback_path;
        const is_fallback = std.mem.eql(u8, path, fallback_path);
        return .{
            .allocator = allocator,
            .txlog = txlog.TxLog.init(allocator, path),
            .txlog_path = path,
            .txlog_path_is_fallback = is_fallback,
        };
    }

    pub fn deinit(self: *Persistence) void {
        self.txlog.deinit();
        if (!self.txlog_path_is_fallback) {
            self.allocator.free(self.txlog_path);
        }
    }
};
