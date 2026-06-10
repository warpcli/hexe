const std = @import("std");
const core = @import("core");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = core.logging.stdLogFn,
};

pub const PodArgs = @import("main.zig").PodArgs;
pub const run = @import("main.zig").run;
