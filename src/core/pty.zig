const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
});

const isolation = @import("isolation.zig");

// External declaration for environ (modified by setenv)
extern var environ: [*:null]?[*:0]u8;

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    child_reaped: bool = false,
    // If true, we don't own the process (ses does) - don't try to kill on close
    external_process: bool = false,

    pub fn spawn(shell: []const u8) !Pty {
        return spawnWithCwd(shell, null);
    }

    pub fn spawnWithCwd(shell: []const u8, cwd: ?[]const u8) !Pty {
        return spawnInternal(shell, cwd, null);
    }

    pub fn spawnWithEnv(shell: []const u8, cwd: ?[]const u8, extra_env: ?[]const [2][]const u8) !Pty {
        return spawnInternal(shell, cwd, extra_env);
    }

    /// Create a Pty from an existing file descriptor
    /// Used when ses daemon owns the PTY and passes us the fd
    pub fn fromFd(fd: posix.fd_t, pid: posix.pid_t) Pty {
        return Pty{
            .master_fd = fd,
            .child_pid = pid,
            .child_reaped = false,
            .external_process = true, // ses owns the process
        };
    }

    fn spawnInternal(shell: []const u8, cwd: ?[]const u8, extra_env: ?[]const [2][]const u8) !Pty {
        var master_fd: c_int = 0;
        var slave_fd: c_int = 0;

        const isolate = isolation.enabledFor(extra_env);

        // Get current terminal size to pass to the new PTY
        var ws: c.winsize = undefined;
        if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) != 0) {
            // Fallback to reasonable defaults
            ws.ws_col = 80;
            ws.ws_row = 24;
            ws.ws_xpixel = 0;
            ws.ws_ypixel = 0;
        }

        if (c.openpty(&master_fd, &slave_fd, null, null, &ws) != 0) {
            return error.OpenPtyFailed;
        }

        const pid = try posix.fork();
        if (pid == 0) {
            // Create new session, becoming session leader
            _ = posix.setsid() catch posix.exit(1);

            // Set the slave PTY as the controlling terminal
            // TIOCSCTTY with arg 0 means "steal" controlling terminal if needed
            if (c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0)) != 0) {
                // Non-fatal, some systems don't require this
            }

            posix.dup2(@intCast(slave_fd), posix.STDIN_FILENO) catch posix.exit(1);
            posix.dup2(@intCast(slave_fd), posix.STDOUT_FILENO) catch posix.exit(1);
            posix.dup2(@intCast(slave_fd), posix.STDERR_FILENO) catch posix.exit(1);
            _ = posix.close(@intCast(slave_fd));
            _ = posix.close(@intCast(master_fd));

            // Change to working directory if specified
            if (cwd) |dir| {
                posix.chdir(dir) catch {};
            }

            if (isolate) {
                isolation.applyChildIsolation(cwd);
            }

            // Build environment: inherit parent env + BOX=1 + TERM override + extra
            const envp = buildEnv(extra_env) catch posix.exit(1);

            // Check if command has spaces (needs shell wrapper)
            const has_spaces = std.mem.indexOfScalar(u8, shell, ' ') != null;

            if (has_spaces) {
                // Use /bin/sh -c "command" for commands with arguments
                const cmd_z = std.heap.c_allocator.dupeZ(u8, shell) catch posix.exit(1);
                var argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null };
                posix.execvpeZ("/bin/sh", &argv, envp) catch posix.exit(1);
            } else {
                // Simple command without arguments
                const shell_z = std.heap.c_allocator.dupeZ(u8, shell) catch posix.exit(1);
                var argv = [_:null]?[*:0]const u8{ shell_z, null };
                posix.execvpeZ(shell_z, &argv, envp) catch posix.exit(1);
            }
            unreachable;
        }

        _ = posix.close(@intCast(slave_fd));

        if (isolate) {
            isolation.applyChildCgroup(extra_env, pid);
        }

        return Pty{
            .master_fd = @intCast(master_fd),
            .child_pid = pid,
        };
    }

    fn buildEnv(extra_env: ?[]const [2][]const u8) ![*:null]const ?[*:0]const u8 {
        const allocator = std.heap.c_allocator;
        var env_list: std.ArrayList(?[*:0]const u8) = .empty;

        // Build list of keys to skip (our overrides + extra env keys)
        var skip_keys: [16][]const u8 = undefined;
        var skip_count: usize = 0;
        skip_keys[skip_count] = "BOX";
        skip_count += 1;
        skip_keys[skip_count] = "TERM";
        skip_count += 1;
        if (extra_env) |extras| {
            for (extras) |kv| {
                if (skip_count < skip_keys.len) {
                    skip_keys[skip_count] = kv[0];
                    skip_count += 1;
                }
            }
        }

        // Copy parent environment from C environ (includes setenv changes)
        var i: usize = 0;
        outer: while (environ[i]) |env_ptr| : (i += 1) {
            const env_str = std.mem.span(env_ptr);
            // Skip keys we're overriding
            for (skip_keys[0..skip_count]) |key| {
                if (std.mem.startsWith(u8, env_str, key) and env_str.len > key.len and env_str[key.len] == '=') {
                    continue :outer;
                }
            }
            try env_list.append(allocator, env_ptr);
        }

        // Add our environment variables
        try env_list.append(allocator, "BOX=1");
        try env_list.append(allocator, "TERM=xterm-256color");

        // Add extra environment variables
        if (extra_env) |extras| {
            for (extras) |kv| {
                // Calculate length needed: key + '=' + value + null
                const len = kv[0].len + 1 + kv[1].len;
                const buf = try allocator.allocSentinel(u8, len, 0);
                @memcpy(buf[0..kv[0].len], kv[0]);
                buf[kv[0].len] = '=';
                @memcpy(buf[kv[0].len + 1 ..][0..kv[1].len], kv[1]);
                try env_list.append(allocator, buf.ptr);
            }
        }

        // Null-terminate
        try env_list.append(allocator, null);

        const slice = try env_list.toOwnedSlice(allocator);
        return @ptrCast(slice.ptr);
    }

    pub fn read(self: Pty, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }

    pub fn write(self: Pty, data: []const u8) !usize {
        return posix.write(self.master_fd, data);
    }

    pub fn pollStatus(self: *Pty) ?u32 {
        if (self.child_reaped) return 0; // Already dead
        // For ses-managed processes, we can't waitpid (not our child)
        // Just check if we can read from the fd as a proxy for alive
        if (self.external_process) return null; // Assume alive
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        if (result.pid == 0) return null; // Still running
        self.child_reaped = true;
        return result.status;
    }

    pub fn close(self: *Pty) void {
        // Close master fd first - this sends EOF to the child
        _ = posix.close(self.master_fd);

        // If ses owns the process, don't try to wait or kill it
        if (self.external_process) {
            return;
        }

        if (!self.child_reaped) {
            // Try non-blocking wait first
            const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
            if (result.pid != 0) {
                self.child_reaped = true;
                return;
            }

            // Still running - send SIGHUP then SIGTERM
            _ = std.c.kill(self.child_pid, std.c.SIG.HUP);

            // Brief wait then check again
            std.Thread.sleep(10 * std.time.ns_per_ms);
            const result2 = posix.waitpid(self.child_pid, posix.W.NOHANG);
            if (result2.pid != 0) {
                self.child_reaped = true;
                return;
            }

            // Force kill if still alive
            _ = std.c.kill(self.child_pid, std.c.SIG.KILL);

            // Never block forever here. If the process is stuck in D-state,
            // even SIGKILL won't terminate it and a blocking waitpid() would
            // hang the caller.
            const kill_deadline_ms: i64 = std.time.milliTimestamp() + 250;
            while (true) {
                const r = posix.waitpid(self.child_pid, posix.W.NOHANG);
                if (r.pid != 0) {
                    self.child_reaped = true;
                    return;
                }
                if (std.time.milliTimestamp() >= kill_deadline_ms) {
                    // Give up on reaping to avoid a hard hang.
                    // This may leave a zombie if the process exits later; the
                    // proper fix is a dedicated reaper (SIGCHLD handling).
                    return;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }
    }

    // Set the terminal size (for window resize handling)
    pub fn setSize(self: Pty, cols: u16, rows: u16) !void {
        var ws: c.winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws) != 0) {
            return error.SetSizeFailed;
        }
    }

    // Get current terminal size
    pub fn getSize(self: Pty) !struct { cols: u16, rows: u16 } {
        var ws: c.winsize = undefined;
        if (c.ioctl(self.master_fd, c.TIOCGWINSZ, &ws) != 0) {
            return error.GetSizeFailed;
        }
        return .{ .cols = ws.ws_col, .rows = ws.ws_row };
    }
};

// Terminal size utilities
pub const TermSize = struct {
    cols: u16,
    rows: u16,

    pub fn fromStdout() TermSize {
        var ws: c.winsize = undefined;
        if (c.ioctl(posix.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
            return .{
                .cols = if (ws.ws_col > 0) ws.ws_col else 80,
                .rows = if (ws.ws_row > 0) ws.ws_row else 24,
            };
        }
        return .{ .cols = 80, .rows = 24 };
    }
};
