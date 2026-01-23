const std = @import("std");
const Segment = @import("../segment.zig").Segment;
const Context = @import("../segment.zig").Context;
const Style = @import("../style.zig").Style;

// Static buffer for branch name (persists across function calls)
var branch_buf: [128]u8 = undefined;
var branch_len: usize = 0;

// Cache for branch name (keyed by cwd hash, 2s TTL)
const BranchCache = struct {
    cwd_hash: u64,
    name_len: u8,
    name_buf: [128]u8,
    timestamp_ms: i64,
};

var branch_cache: ?BranchCache = null;

fn hashCwd(cwd: []const u8) u64 {
    var h: u64 = 5381;
    for (cwd) |c| {
        h = ((h << 5) +% h) +% c;
    }
    return h;
}

/// Git branch segment - displays current git branch
/// Format:  main
pub fn render(ctx: *Context) ?[]const Segment {
    const cwd = if (ctx.cwd.len > 0) ctx.cwd else std.posix.getenv("PWD") orelse return null;

    const now = std.time.milliTimestamp();
    const cwd_hash = hashCwd(cwd);

    // Check cache (2s TTL)
    if (branch_cache) |cached| {
        if (cached.cwd_hash == cwd_hash and (now - cached.timestamp_ms) < 2000 and cached.name_len > 0) {
            const text = ctx.allocText(cached.name_buf[0..cached.name_len]) catch return null;
            return ctx.addSegment(text, Style.parse("bold fg:magenta")) catch return null;
        }
    }

    // Check if we're in a git repo by looking for .git directory
    if (!isGitRepo(cwd)) return null;

    // Get branch name into static buffer
    const branch = getBranchName(cwd) orelse return null;

    // Cache the result
    var cache_entry = BranchCache{
        .cwd_hash = cwd_hash,
        .name_len = @intCast(@min(branch.len, 128)),
        .name_buf = undefined,
        .timestamp_ms = now,
    };
    @memcpy(cache_entry.name_buf[0..cache_entry.name_len], branch[0..cache_entry.name_len]);
    branch_cache = cache_entry;

    // Return just the branch name - config controls the icon (e.g., "  $output")
    const text = ctx.allocText(branch) catch return null;

    return ctx.addSegment(text, Style.parse("bold fg:magenta")) catch return null;
}

fn isGitRepo(cwd: []const u8) bool {
    // Walk up directory tree looking for .git
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var current: []const u8 = cwd;

    while (true) {
        // Check for .git directory
        const git_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{current}) catch return false;
        if (std.fs.cwd().access(git_path, .{})) |_| {
            return true;
        } else |_| {}

        // Check for .git file (worktree/submodule)
        if (std.fs.openFileAbsolute(git_path, .{})) |file| {
            file.close();
            return true;
        } else |_| {}

        // Move up one directory
        if (std.mem.lastIndexOfScalar(u8, current, '/')) |idx| {
            if (idx == 0) {
                // Check root
                if (std.fs.cwd().access("/.git", .{})) |_| {
                    return true;
                } else |_| {}
                return false;
            }
            current = current[0..idx];
        } else {
            return false;
        }
    }
}

fn getBranchName(cwd: []const u8) ?[]const u8 {
    // Find .git directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var git_dir_len: usize = 0;
    var current: []const u8 = cwd;

    while (true) {
        const git_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{current}) catch return null;

        // Check if it's a directory
        if (std.fs.openDirAbsolute(git_path, .{})) |dir| {
            var d = dir;
            d.close();
            // Copy to stable buffer
            @memcpy(git_dir_buf[0..git_path.len], git_path);
            git_dir_len = git_path.len;
            break;
        } else |_| {}

        // Check if it's a file (worktree)
        if (std.fs.openFileAbsolute(git_path, .{})) |file| {
            defer file.close();
            var buf: [256]u8 = undefined;
            const len = file.read(&buf) catch return null;
            const content = std.mem.trim(u8, buf[0..len], " \t\n\r");
            // Format: "gitdir: /path/to/.git/worktrees/name"
            if (std.mem.startsWith(u8, content, "gitdir: ")) {
                const gitdir_path = content[8..];
                @memcpy(git_dir_buf[0..gitdir_path.len], gitdir_path);
                git_dir_len = gitdir_path.len;
                break;
            }
            return null;
        } else |_| {}

        // Move up
        if (std.mem.lastIndexOfScalar(u8, current, '/')) |idx| {
            if (idx == 0) return null;
            current = current[0..idx];
        } else {
            return null;
        }
    }

    if (git_dir_len == 0) return null;
    const git_dir = git_dir_buf[0..git_dir_len];

    // Read HEAD file
    const head_path = std.fmt.bufPrint(&path_buf, "{s}/HEAD", .{git_dir}) catch return null;

    const file = std.fs.openFileAbsolute(head_path, .{}) catch return null;
    defer file.close();

    var buf: [256]u8 = undefined;
    const len = file.read(&buf) catch return null;
    const content = std.mem.trim(u8, buf[0..len], " \t\n\r");

    // Check for symbolic ref (branch)
    if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
        const name = content[16..];
        const copy_len = @min(name.len, branch_buf.len);
        @memcpy(branch_buf[0..copy_len], name[0..copy_len]);
        branch_len = copy_len;
        return branch_buf[0..branch_len];
    }

    // Detached HEAD - return short hash
    if (content.len >= 7) {
        const hash = content[0..7];
        @memcpy(branch_buf[0..7], hash);
        branch_len = 7;
        return branch_buf[0..branch_len];
    }

    return null;
}
