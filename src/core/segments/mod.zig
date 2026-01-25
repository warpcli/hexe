const std = @import("std");
const context = @import("context.zig");
pub const Segment = context.Segment;
pub const Context = context.Context;
pub const SegmentFn = context.SegmentFn;

// System stats segments (for mux status bar)
pub const time = @import("time.zig");
pub const netspeed = @import("netspeed.zig");
pub const uptime = @import("uptime.zig");
pub const cpu = @import("cpu.zig");
pub const memory = @import("memory.zig");
pub const battery = @import("battery.zig");
pub const last_command = @import("last_command.zig");
pub const running_anim = @import("running_anim.zig");
pub const randomdo = @import("randomdo.zig");

// Shell context segments (for prompt)
pub const directory = @import("directory.zig");
pub const hostname = @import("hostname.zig");
pub const username = @import("username.zig");

// Git segments
pub const git_branch = @import("git_branch.zig");
pub const git_status = @import("git_status.zig");

// Shell state segments
pub const status = @import("status.zig");
pub const sudo = @import("sudo.zig");
pub const character = @import("character.zig");
pub const duration = @import("duration.zig");
pub const jobs = @import("jobs.zig");

// Custom segments (shell command runner)
pub const custom = @import("custom.zig");

// Animations
pub const animations = @import("animations/mod.zig");

/// Registry of built-in segments
pub const registry = std.StaticStringMap(SegmentFn).initComptime(.{
    // System stats (mux status bar)
    .{ "time", time.render },
    .{ "netspeed", netspeed.render },
    .{ "uptime", uptime.render },
    .{ "cpu", cpu.render },
    .{ "mem", memory.render },
    .{ "memory", memory.render },
    .{ "battery", battery.render },
    .{ "last_command", last_command.render },
    .{ "cmd", last_command.render },
    .{ "running_anim", running_anim.render },
    .{ "randomdo", randomdo.render },

    // Shell context (prompt)
    .{ "directory", directory.render },
    .{ "dir", directory.render },
    .{ "hostname", hostname.render },
    .{ "host", hostname.render },
    .{ "username", username.render },
    .{ "user", username.render },

    // Git
    .{ "git_branch", git_branch.render },
    .{ "git", git_branch.render },
    .{ "git_status", git_status.render },

    // Shell state
    .{ "status", status.render },
    .{ "sudo", sudo.render },
    .{ "character", character.render },
    .{ "char", character.render },
    .{ "duration", duration.render },
    .{ "jobs", jobs.render },
});
