const std = @import("std");
const frontend_client = @import("frontend_client.zig");

pub const FrontendAttachState = struct {
    detach_mode: bool = false,
    reattach_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    adopt_orphans: [32]frontend_client.OrphanedPaneInfo = undefined,
    adopt_orphan_count: usize = 0,
    adopt_selected_uuid: ?[32]u8 = null,
    state_version: u32 = 0,

    pub fn nextStateVersion(self: *FrontendAttachState) u32 {
        self.state_version +%= 1;
        return self.state_version;
    }
};
