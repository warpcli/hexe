const std = @import("std");
const Style = @import("style.zig").Style;

/// A rendered segment with text and style
pub const Segment = struct {
    text: []const u8,
    style: Style = .{},
};

/// Segment render function signature
pub const SegmentFn = *const fn (ctx: *Context) ?[]const Segment;

/// Context passed to all segments during rendering
pub const Context = struct {
    allocator: std.mem.Allocator,

    // Environment
    cwd: []const u8 = "",
    home: ?[]const u8 = null,
    terminal_width: u16 = 80,

    // Shell state (for prompt mode)
    exit_status: ?i32 = null,
    cmd_duration_ms: ?u64 = null,
    jobs: u16 = 0,

    // Shell metadata (for mux status bar mode)
    last_command: ?[]const u8 = null,

    // Shell activity telemetry (for mux status bar mode)
    shell_running: bool = false,
    shell_running_cmd: ?[]const u8 = null,
    shell_started_at_ms: ?u64 = null,

    // Mux pane state (for mux status bar mode)
    alt_screen: bool = false,

    // Mux focus state (for mux status bar mode)
    focus_is_float: bool = false,
    focus_is_split: bool = true,

    // Focused float attributes (for mux status bar mode)
    float_key: u8 = 0,
    float_destroyable: bool = false,
    float_exclusive: bool = false,
    float_per_cwd: bool = false,
    float_global: bool = false,
    float_sticky: bool = false,
    float_isolated: bool = false,

    tab_count: u16 = 0,

    // Clock (ms since epoch) for animations/time-based segments
    now_ms: u64 = 0,

    // Default style provided by the caller (mux statusbar) for the currently
    // rendered module output.
    //
    // Some segments (e.g. running_anim) derive color ramps from this.
    module_default_style: Style = .{},

    // Mux state (for status bar mode)
    session_name: []const u8 = "",
    tab_names: []const []const u8 = &.{},
    active_tab: usize = 0,

    // Segment output storage
    segment_buffer: std.ArrayList(Segment) = .empty,
    text_buffer: std.ArrayList(u8) = .empty,

    // Cached segment outputs
    cached_segments: std.StringHashMap([]const Segment),

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .cached_segments = std.StringHashMap([]const Segment).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.segment_buffer.deinit(self.allocator);
        self.text_buffer.deinit(self.allocator);
        self.cached_segments.deinit();
    }

    /// Get environment variable
    pub fn getEnv(self: *Context, key: []const u8) ?[]const u8 {
        _ = self;
        return std.posix.getenv(key);
    }

    /// Render a segment by name and return its segments
    pub fn renderSegment(self: *Context, name: []const u8) ?[]const Segment {
        // Dynamic segments (cpu, mem, netspeed, time) should not be cached
        // since they need fresh values each render
        const dynamic_segments = [_][]const u8{ "cpu", "mem", "memory", "netspeed", "time", "battery", "uptime", "last_command", "randomdo" };
        var is_dynamic = false;
        if (std.mem.eql(u8, name, "running_anim") or std.mem.startsWith(u8, name, "running_anim/")) {
            is_dynamic = true;
        }
        for (dynamic_segments) |dyn| {
            if (std.mem.eql(u8, name, dyn)) {
                is_dynamic = true;
                break;
            }
        }

        // Parameterized running animation segment: running_anim/<spinner>?width=8&step=75&hold=9
        if (std.mem.eql(u8, name, "running_anim") or std.mem.startsWith(u8, name, "running_anim/")) {
            const segments_mod = @import("segments/mod.zig");
            return segments_mod.running_anim.renderNamed(self, name);
        }

        // Check cache first (only for non-dynamic segments)
        if (!is_dynamic) {
            if (self.cached_segments.get(name)) |segs| {
                return segs;
            }
        }

        // Look up in built-in segments
        const segments_mod = @import("segments/mod.zig");
        if (segments_mod.registry.get(name)) |render_fn| {
            if (render_fn(self)) |segs| {
                // Cache non-dynamic segments
                if (!is_dynamic) {
                    self.cached_segments.put(name, segs) catch {};
                }
                return segs;
            }
        }

        // Check for custom.* segments
        if (std.mem.startsWith(u8, name, "custom.")) {
            // TODO: Handle custom segments from config
            return null;
        }

        // Check for mux-specific segments
        if (std.mem.eql(u8, name, "tabs")) {
            return self.renderTabs();
        }
        if (std.mem.eql(u8, name, "session")) {
            return self.renderSession();
        }

        return null;
    }

    /// Render tab names for mux status bar
    fn renderTabs(self: *Context) ?[]const Segment {
        if (self.tab_names.len == 0) return null;

        self.segment_buffer.clearRetainingCapacity();

        for (self.tab_names, 0..) |tab_name, i| {
            const is_active = i == self.active_tab;

            // Add separator between tabs
            if (i > 0) {
                self.segment_buffer.append(self.allocator, .{
                    .text = " | ",
                    .style = Style.parse("fg:7"),
                }) catch return null;
            }

            // Add tab name with active/inactive styling
            const style = if (is_active)
                Style.parse("bg:1 fg:0")
            else
                Style.parse("bg:237 fg:250");

            self.segment_buffer.append(self.allocator, .{
                .text = tab_name,
                .style = style,
            }) catch return null;
        }

        return self.segment_buffer.items;
    }

    /// Render session name for mux status bar
    fn renderSession(self: *Context) ?[]const Segment {
        if (self.session_name.len == 0) return null;

        self.segment_buffer.clearRetainingCapacity();
        self.segment_buffer.append(self.allocator, .{
            .text = self.session_name,
            .style = Style{},
        }) catch return null;

        return self.segment_buffer.items;
    }

    /// Allocate text that persists for the render lifetime
    pub fn allocText(self: *Context, text: []const u8) ![]const u8 {
        const start = self.text_buffer.items.len;
        try self.text_buffer.appendSlice(self.allocator, text);
        return self.text_buffer.items[start..];
    }

    /// Format and allocate text
    pub fn allocFmt(self: *Context, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const start = self.text_buffer.items.len;
        try self.text_buffer.writer(self.allocator).print(fmt, args);
        return self.text_buffer.items[start..];
    }

    /// Add a segment to the output buffer and return it
    pub fn addSegment(self: *Context, text: []const u8, style: Style) ![]const Segment {
        self.segment_buffer.clearRetainingCapacity();
        try self.segment_buffer.append(self.allocator, .{ .text = text, .style = style });
        return self.segment_buffer.items;
    }
};
