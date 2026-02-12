/// Resource limits and monitoring for preventing resource exhaustion
const std = @import("std");
const constants = @import("constants.zig");

/// Resource usage statistics for monitoring
pub const ResourceStats = struct {
    /// Total active connections
    active_connections: usize = 0,

    /// Total active sessions
    active_sessions: usize = 0,

    /// Total active panes
    active_panes: usize = 0,

    /// Total memory allocated (approximate)
    memory_bytes: usize = 0,

    /// Connection attempts in last minute
    recent_connections: usize = 0,

    /// Timestamp of last stats update
    last_update_ms: i64 = 0,

    pub fn reset(self: *ResourceStats) void {
        self.* = .{};
    }
};

/// Resource limits configuration
pub const ResourceLimits = struct {
    /// Maximum concurrent client connections (default: 64)
    max_connections: usize = constants.Limits.max_clients,

    /// Maximum panes per session (default: 1000)
    max_panes_per_session: usize = 1000,

    /// Maximum sessions (default: 100)
    max_sessions: usize = 100,

    /// Maximum memory per session in MB (default: 500MB)
    max_memory_per_session_mb: usize = 500,

    /// Maximum connection rate per minute (default: 60)
    max_connections_per_minute: usize = 60,

    /// Load from environment variables
    pub fn fromEnv() ResourceLimits {
        var limits = ResourceLimits{};

        if (std.posix.getenv("HEXE_MAX_CONNECTIONS")) |val| {
            limits.max_connections = std.fmt.parseInt(usize, val, 10) catch limits.max_connections;
        }

        if (std.posix.getenv("HEXE_MAX_PANES_PER_SESSION")) |val| {
            limits.max_panes_per_session = std.fmt.parseInt(usize, val, 10) catch limits.max_panes_per_session;
        }

        if (std.posix.getenv("HEXE_MAX_SESSIONS")) |val| {
            limits.max_sessions = std.fmt.parseInt(usize, val, 10) catch limits.max_sessions;
        }

        if (std.posix.getenv("HEXE_MAX_MEMORY_PER_SESSION_MB")) |val| {
            limits.max_memory_per_session_mb = std.fmt.parseInt(usize, val, 10) catch limits.max_memory_per_session_mb;
        }

        if (std.posix.getenv("HEXE_MAX_CONNECTIONS_PER_MINUTE")) |val| {
            limits.max_connections_per_minute = std.fmt.parseInt(usize, val, 10) catch limits.max_connections_per_minute;
        }

        return limits;
    }
};

/// Connection rate limiter for preventing DoS
pub const RateLimiter = struct {
    /// Timestamps of recent connections (circular buffer)
    connection_times: [100]i64 = [_]i64{0} ** 100,
    /// Current write position in circular buffer
    write_pos: usize = 0,
    /// Window size in milliseconds (default: 60 seconds)
    window_ms: i64 = 60000,

    /// Record a new connection attempt
    pub fn recordConnection(self: *RateLimiter, now_ms: i64) void {
        self.connection_times[self.write_pos] = now_ms;
        self.write_pos = (self.write_pos + 1) % self.connection_times.len;
    }

    /// Count connections in the current window
    pub fn getRecentConnections(self: *const RateLimiter, now_ms: i64) usize {
        var count: usize = 0;
        const cutoff = now_ms - self.window_ms;

        for (self.connection_times) |time| {
            if (time > cutoff) {
                count += 1;
            }
        }

        return count;
    }

    /// Check if rate limit is exceeded
    pub fn isRateLimited(self: *const RateLimiter, now_ms: i64, max_per_window: usize) bool {
        return self.getRecentConnections(now_ms) >= max_per_window;
    }
};

/// Resource monitor for tracking usage
pub const ResourceMonitor = struct {
    stats: ResourceStats = .{},
    limits: ResourceLimits,
    rate_limiter: RateLimiter = .{},

    pub fn init(limits: ResourceLimits) ResourceMonitor {
        return .{ .limits = limits };
    }

    /// Update statistics
    pub fn updateStats(
        self: *ResourceMonitor,
        connections: usize,
        sessions: usize,
        panes: usize,
        memory_bytes: usize,
    ) void {
        self.stats.active_connections = connections;
        self.stats.active_sessions = sessions;
        self.stats.active_panes = panes;
        self.stats.memory_bytes = memory_bytes;
        self.stats.last_update_ms = std.time.milliTimestamp();
    }

    /// Check if a new connection should be allowed
    pub fn allowNewConnection(self: *ResourceMonitor) bool {
        const now = std.time.milliTimestamp();

        // Check connection count limit
        if (self.stats.active_connections >= self.limits.max_connections) {
            return false;
        }

        // Check rate limit
        if (self.rate_limiter.isRateLimited(now, self.limits.max_connections_per_minute)) {
            return false;
        }

        return true;
    }

    /// Record a new connection
    pub fn recordConnection(self: *ResourceMonitor) void {
        const now = std.time.milliTimestamp();
        self.rate_limiter.recordConnection(now);
        self.stats.recent_connections = self.rate_limiter.getRecentConnections(now);
    }

    /// Check if a new session should be allowed
    pub fn allowNewSession(self: *const ResourceMonitor) bool {
        return self.stats.active_sessions < self.limits.max_sessions;
    }

    /// Check if a session can create more panes
    pub fn allowNewPane(self: *const ResourceMonitor, session_pane_count: usize) bool {
        return session_pane_count < self.limits.max_panes_per_session;
    }

    /// Get current statistics
    pub fn getStats(self: *const ResourceMonitor) ResourceStats {
        return self.stats;
    }
};
