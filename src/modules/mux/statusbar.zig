const std = @import("std");
const core = @import("core");
const shp = @import("shp");
const animations = core.segments.animations;
const randomdo_mod = core.segments.randomdo;

const LuaRuntime = core.LuaRuntime;

const State = @import("state.zig").State;
const render = @import("render.zig");
const Pane = @import("pane.zig").Pane;

const WhenCacheEntry = struct {
    last_eval_ms: u64,
    last_result: bool,
};

threadlocal var when_bash_cache: ?std.AutoHashMap(usize, WhenCacheEntry) = null;
threadlocal var when_lua_cache: ?std.AutoHashMap(usize, WhenCacheEntry) = null;
threadlocal var when_lua_rt: ?LuaRuntime = null;

const RandomdoState = struct {
    active: bool,
    idx: u16,
};

threadlocal var randomdo_state: ?std.AutoHashMap(usize, RandomdoState) = null;

fn getRandomdoStateMap() *std.AutoHashMap(usize, RandomdoState) {
    if (randomdo_state == null) {
        randomdo_state = std.AutoHashMap(usize, RandomdoState).init(std.heap.page_allocator);
    }
    return &randomdo_state.?;
}

fn randomdoKey(mod: core.config.Segment) usize {
    return (@intFromPtr(mod.outputs.ptr) << 1) ^ @as(usize, mod.priority) ^ mod.name.len;
}

fn randomdoTextFor(ctx: *shp.Context, mod: core.config.Segment, visible: bool) []const u8 {
    const key = randomdoKey(mod);
    const map = getRandomdoStateMap();

    if (!visible) {
        if (map.getPtr(key)) |st| st.active = false;
        return "";
    }

    var entry = map.getPtr(key);
    if (entry == null) {
        map.put(key, .{ .active = false, .idx = 0 }) catch {};
        entry = map.getPtr(key);
    }
    if (entry) |st| {
        if (!st.active) {
            const idx = randomdo_mod.chooseIndex(ctx.now_ms, ctx.cwd);
            st.idx = @intCast(idx);
            st.active = true;
        }
        return randomdo_mod.WORDS[@min(@as(usize, st.idx), randomdo_mod.WORDS.len - 1)];
    }
    return "";
}

fn whenKey(s: []const u8) usize {
    return (@intFromPtr(s.ptr) << 1) ^ s.len;
}

fn getWhenCache(map_ptr: *?std.AutoHashMap(usize, WhenCacheEntry)) *std.AutoHashMap(usize, WhenCacheEntry) {
    if (map_ptr.* == null) {
        map_ptr.* = std.AutoHashMap(usize, WhenCacheEntry).init(std.heap.page_allocator);
    }
    return &map_ptr.*.?;
}

/// Build a PaneQuery from the populated rendering context.
fn queryFromContext(ctx: *const shp.Context) core.PaneQuery {
    return .{
        .is_float = ctx.focus_is_float,
        .is_split = ctx.focus_is_split,
        .float_key = ctx.float_key,
        .float_sticky = ctx.float_sticky,
        .float_exclusive = ctx.float_exclusive,
        .float_per_cwd = ctx.float_per_cwd,
        .float_global = ctx.float_global,
        .float_isolated = ctx.float_isolated,
        .float_destroyable = ctx.float_destroyable,
        .tab_count = ctx.tab_count,
        .active_tab = @intCast(ctx.active_tab),
        .alt_screen = ctx.alt_screen,
        .cwd = if (ctx.cwd.len > 0) ctx.cwd else null,
        .last_command = ctx.last_command,
        .exit_status = ctx.exit_status,
        .cmd_duration_ms = ctx.cmd_duration_ms,
        .jobs = ctx.jobs,
        .shell_running = ctx.shell_running,
        .shell_running_cmd = ctx.shell_running_cmd,
        .shell_started_at_ms = ctx.shell_started_at_ms,
        .session_name = ctx.session_name,
        .now_ms = ctx.now_ms,
    };
}

fn evalBashWhen(code: []const u8, ctx: *shp.Context, ttl_ms: u64) bool {
    const now = ctx.now_ms;
    const key = whenKey(code);
    const map = getWhenCache(&when_bash_cache);
    if (map.get(key)) |e| {
        if (now - e.last_eval_ms < ttl_ms) return e.last_result;
    }

    // Export a few useful ctx vars.
    var env_map = std.process.EnvMap.init(std.heap.page_allocator);
    defer env_map.deinit();
    env_map.put("HEXE_STATUS_PROCESS_RUNNING", if (ctx.shell_running) "1" else "0") catch {};
    env_map.put("HEXE_STATUS_ALT_SCREEN", if (ctx.alt_screen) "1" else "0") catch {};
    if (ctx.last_command) |c| env_map.put("HEXE_STATUS_LAST_CMD", c) catch {};
    if (ctx.cwd.len > 0) env_map.put("HEXE_STATUS_CWD", ctx.cwd) catch {};

    const res = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "/bin/bash", "-c", code },
        .env_map = &env_map,
    }) catch {
        map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
        return false;
    };
    std.heap.page_allocator.free(res.stdout);
    std.heap.page_allocator.free(res.stderr);
    const ok = switch (res.term) {
        .Exited => |ec| ec == 0,
        else => false,
    };
    map.put(key, .{ .last_eval_ms = now, .last_result = ok }) catch {};
    return ok;
}

fn evalLuaWhen(code: []const u8, ctx: *shp.Context, ttl_ms: u64) bool {
    const now = ctx.now_ms;
    const key = whenKey(code);
    const map = getWhenCache(&when_lua_cache);
    if (map.get(key)) |e| {
        if (now - e.last_eval_ms < ttl_ms) return e.last_result;
    }

    if (when_lua_rt == null) {
        when_lua_rt = LuaRuntime.init(std.heap.page_allocator) catch null;
        if (when_lua_rt == null) {
            map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
            return false;
        }
    }
    const rt = &when_lua_rt.?;

    // ctx table
    rt.lua.createTable(0, 8);
    rt.lua.pushBoolean(ctx.shell_running);
    rt.lua.setField(-2, "shell_running");
    rt.lua.pushBoolean(ctx.alt_screen);
    rt.lua.setField(-2, "alt_screen");
    rt.lua.pushInteger(ctx.jobs);
    rt.lua.setField(-2, "jobs");
    if (ctx.exit_status) |st| {
        rt.lua.pushInteger(st);
        rt.lua.setField(-2, "last_status");
    }
    if (ctx.last_command) |c| {
        _ = rt.lua.pushString(c);
        rt.lua.setField(-2, "last_command");
    }
    _ = rt.lua.pushString(ctx.cwd);
    rt.lua.setField(-2, "cwd");
    rt.lua.pushInteger(@intCast(ctx.now_ms));
    rt.lua.setField(-2, "now_ms");
    rt.lua.setGlobal("ctx");

    const code_z = rt.allocator.dupeZ(u8, code) catch {
        map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
        return false;
    };
    defer rt.allocator.free(code_z);

    rt.lua.loadString(code_z) catch {
        map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
        return false;
    };
    rt.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        rt.lua.pop(1);
        map.put(key, .{ .last_eval_ms = now, .last_result = false }) catch {};
        return false;
    };
    const ok = if (rt.lua.typeOf(-1) == .boolean) rt.lua.toBoolean(-1) else false;
    rt.lua.pop(1);
    map.put(key, .{ .last_eval_ms = now, .last_result = ok }) catch {};
    return ok;
}

fn passesWhen(ctx: *shp.Context, query: *const core.PaneQuery, mod: core.config.Segment) bool {
    if (mod.when == null) return true;
    return passesWhenClause(ctx, query, mod.when.?);
}

fn passesWhenClause(ctx: *shp.Context, query: *const core.PaneQuery, w: core.WhenDef) bool {
    // Token-based 'all' conditions
    if (w.all) |tokens| {
        for (tokens) |t| {
            if (!core.query.evalToken(query, t)) return false;
        }
    }

    // Nested 'any' conditions (OR): at least one must match
    if (w.any) |clauses| {
        var any_match = false;
        for (clauses) |c| {
            if (passesWhenClause(ctx, query, c)) {
                any_match = true;
                break;
            }
        }
        if (!any_match) return false;
    }

    // Lua/bash conditions — evaluated with caching
    if (w.lua) |lua_code| {
        if (!evalLuaWhen(lua_code, ctx, 500)) return false;
    }
    if (w.bash) |bash_code| {
        if (!evalBashWhen(bash_code, ctx, 2000)) return false;
    }

    return true;
}

pub const Renderer = render.Renderer;

pub const RenderedSegment = struct {
    text: []const u8,
    fg: render.Color,
    bg: render.Color,
    bold: bool,
    italic: bool,
};

pub const RenderedSegments = struct {
    items: [16]RenderedSegment,
    buffers: [16][64]u8,
    count: usize,
    total_len: usize,
};

pub fn renderSegmentOutput(module: *const core.Segment, output: []const u8) RenderedSegments {
    var result = RenderedSegments{
        .items = undefined,
        .buffers = undefined,
        .count = 0,
        .total_len = 0,
    };

    for (module.outputs) |out| {
        if (result.count >= 16) break;

        var text_len: usize = 0;
        var i: usize = 0;
        while (i < out.format.len and text_len < 64) {
            if (i + 6 < out.format.len and std.mem.eql(u8, out.format[i .. i + 7], "$output")) {
                const copy_len = @min(output.len, 64 - text_len);
                @memcpy(result.buffers[result.count][text_len .. text_len + copy_len], output[0..copy_len]);
                text_len += copy_len;
                i += 7;
            } else {
                result.buffers[result.count][text_len] = out.format[i];
                text_len += 1;
                i += 1;
            }
        }

        const style = shp.Style.parse(out.style);

        result.items[result.count] = .{
            .text = result.buffers[result.count][0..text_len],
            .fg = if (style.fg != .none) styleColorToRender(style.fg) else .none,
            .bg = if (style.bg != .none) styleColorToRender(style.bg) else .none,
            .bold = style.bold,
            .italic = style.italic,
        };
        result.total_len += text_len;
        result.count += 1;
    }

    return result;
}

pub fn styleColorToRender(col: shp.Color) render.Color {
    return switch (col) {
        .none => .none,
        .palette => |p| .{ .palette = p },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

pub fn runSegment(module: *const core.Segment, buf: []u8) ![]const u8 {
    if (module.command) |cmd| {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "/bin/sh", "-c", cmd },
        }) catch return "";
        defer std.heap.page_allocator.free(result.stdout);
        defer std.heap.page_allocator.free(result.stderr);

        var len = result.stdout.len;
        while (len > 0 and (result.stdout[len - 1] == '\n' or result.stdout[len - 1] == '\r')) {
            len -= 1;
        }
        const copy_len = @min(len, buf.len);
        @memcpy(buf[0..copy_len], result.stdout[0..copy_len]);
        return buf[0..copy_len];
    }

    const copy_len = @min(module.name.len, buf.len);
    @memcpy(buf[0..copy_len], module.name[0..copy_len]);
    return buf[0..copy_len];
}

pub fn draw(
    renderer: *Renderer,
    state: *State,
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
) void {
    const y = term_height - 1;
    const width = term_width;
    const cfg = &config.tabs.status;

    // Clear status bar
    for (0..width) |xi| {
        renderer.setCell(@intCast(xi), y, .{ .char = ' ' });
    }

    // Create shp context
    var ctx = shp.Context.init(allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;

    ctx.now_ms = @intCast(std.time.milliTimestamp());

    // Provide shell metadata for status modules.
    // Also ensure we have a stable `shell_started_at_ms` while a float is focused,
    // so spinner modules can animate even without shell hooks.
    if (state.getCurrentFocusedUuid()) |uuid| {
        if (state.active_floating != null) {
            const info_opt = state.getPaneShell(uuid);
            const needs_start = if (info_opt) |info| info.started_at_ms == null else true;
            if (needs_start) {
                state.setPaneShellRunning(uuid, false, ctx.now_ms, null, null, null);
            }
        }

        if (state.getPaneShell(uuid)) |info| {
            if (info.cmd) |c| {
                ctx.last_command = c;
            }
            if (info.cwd) |c| {
                ctx.cwd = c;
            }
            if (info.status) |st| {
                ctx.exit_status = st;
            }
            if (info.duration_ms) |d| {
                ctx.cmd_duration_ms = d;
            }
            if (info.jobs) |j| {
                ctx.jobs = j;
            }

            ctx.shell_running = info.running;
            if (info.cmd) |c| ctx.shell_running_cmd = c;
            ctx.shell_started_at_ms = info.started_at_ms;
        }
    }

    // Mux focus state.
    ctx.tab_count = @intCast(@min(tabs.items.len, @as(usize, std.math.maxInt(u16))));
    ctx.focus_is_float = state.active_floating != null;
    ctx.focus_is_split = state.active_floating == null;

    // Provide pane state for animation policy + float attributes.
    if (state.active_floating) |idx| {
        if (idx < state.floats.items.len) {
            ctx.alt_screen = state.floats.items[idx].vt.inAltScreen();

            const fp = state.floats.items[idx];
            ctx.float_key = fp.float_key;
            ctx.float_sticky = fp.sticky;
            ctx.float_global = fp.parent_tab == null;

            if (fp.float_key != 0) {
                if (state.getLayoutFloatByKey(fp.float_key)) |fd| {
                    ctx.float_destroyable = fd.attributes.destroy;
                    ctx.float_exclusive = fd.attributes.exclusive;
                    ctx.float_per_cwd = fd.attributes.per_cwd;
                    ctx.float_isolated = fd.attributes.isolated;
                    ctx.float_global = ctx.float_global or fd.attributes.global;
                }
            }
        }
    } else if (state.currentLayout().getFocusedPane()) |pane| {
        ctx.alt_screen = pane.vt.inAltScreen();
    }

    // Find the tabs module to check tab_title setting
    var use_basename = true;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            use_basename = std.mem.eql(u8, mod.tab_title, "basename");
            break;
        }
    }

    // Collect tab titles for center section
    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    for (tabs.items) |*tab| {
        if (tab_count < 16) {
            if (use_basename) {
                if (tab.layout.getFocusedPane()) |pane| {
                    const pwd = pane.getRealCwd();
                    tab_names[tab_count] = if (pwd) |p| blk: {
                        const base = std.fs.path.basename(p);
                        break :blk if (base.len == 0) "/" else base;
                    } else tab.name;
                } else {
                    tab_names[tab_count] = tab.name;
                }
            } else {
                tab_names[tab_count] = tab.name;
            }
            tab_count += 1;
        }
    }
    ctx.tab_names = tab_names[0..tab_count];
    ctx.active_tab = active_tab;
    ctx.session_name = session_name;

    // Build PaneQuery for condition evaluation
    const query = queryFromContext(&ctx);

    // === PRIORITY-BASED LAYOUT ===
    // Measure center (tabs) width and get arrow config
    var center_width: u16 = 0;
    var tabs_left_arrow: []const u8 = "";
    var tabs_right_arrow: []const u8 = "";
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            tabs_left_arrow = mod.left_arrow;
            tabs_right_arrow = mod.right_arrow;
            center_width = measureTabsWidth(ctx.tab_names, mod.separator, mod.left_arrow, mod.right_arrow);
            break;
        }
    }

    // True center position
    const center_start = (width -| center_width) / 2;
    const left_budget = center_start;
    const right_budget = width -| (center_start +| center_width);

    // Collect left modules with widths
    const ModuleInfo = struct { mod: *const core.Segment, width: u16, visible: bool };
    var left_modules: [24]ModuleInfo = undefined;
    var left_count: usize = 0;
    for (cfg.left) |*mod| {
        if (left_count < 24) {
            left_modules[left_count] = .{
                .mod = mod,
                .width = calcModuleWidth(&ctx, &query, mod.*),
                .visible = false,
            };
            left_count += 1;
        }
    }

    // Sort left by priority and mark visible
    var left_order: [24]usize = undefined;
    for (0..left_count) |i| left_order[i] = i;
    for (1..left_count) |i| {
        const key = left_order[i];
        var j: usize = i;
        while (j > 0 and left_modules[left_order[j - 1]].mod.priority > left_modules[key].mod.priority) : (j -= 1) {
            left_order[j] = left_order[j - 1];
        }
        left_order[j] = key;
    }
    var left_used: u16 = 0;
    for (left_order[0..left_count]) |idx| {
        if (left_used + left_modules[idx].width <= left_budget) {
            left_modules[idx].visible = true;
            left_used += left_modules[idx].width;
        }
    }

    // Update randomdo visibility state (off->on changes word).
    for (0..left_count) |i| {
        if (std.mem.eql(u8, left_modules[i].mod.name, "randomdo")) {
            const shown = left_modules[i].visible and left_modules[i].width != 0;
            _ = randomdoTextFor(&ctx, left_modules[i].mod.*, shown);
        }
    }

    // Collect right modules with widths
    var right_modules: [24]ModuleInfo = undefined;
    var right_count: usize = 0;
    for (cfg.right) |*mod| {
        if (right_count < 24) {
            right_modules[right_count] = .{
                .mod = mod,
                .width = calcModuleWidth(&ctx, &query, mod.*),
                .visible = false,
            };
            right_count += 1;
        }
    }

    // Sort right by priority and mark visible
    var right_order: [24]usize = undefined;
    for (0..right_count) |i| right_order[i] = i;
    for (1..right_count) |i| {
        const key = right_order[i];
        var j: usize = i;
        while (j > 0 and right_modules[right_order[j - 1]].mod.priority > right_modules[key].mod.priority) : (j -= 1) {
            right_order[j] = right_order[j - 1];
        }
        right_order[j] = key;
    }
    var right_used: u16 = 0;
    for (right_order[0..right_count]) |idx| {
        if (right_used + right_modules[idx].width <= right_budget) {
            right_modules[idx].visible = true;
            right_used += right_modules[idx].width;
        }
    }

    for (0..right_count) |i| {
        if (std.mem.eql(u8, right_modules[i].mod.name, "randomdo")) {
            const shown = right_modules[i].visible and right_modules[i].width != 0;
            _ = randomdoTextFor(&ctx, right_modules[i].mod.*, shown);
        }
    }

    // === DRAW LEFT SECTION ===
    var left_x: u16 = 0;
    for (0..left_count) |i| {
        if (left_modules[i].visible) {
            left_x = drawModule(renderer, &ctx, &query, left_modules[i].mod.*, left_x, y);
        }
    }

    // === DRAW RIGHT SECTION (from right edge) ===
    const right_start = width -| right_used;
    var rx: u16 = right_start;
    for (0..right_count) |i| {
        if (right_modules[i].visible) {
            rx = drawModule(renderer, &ctx, &query, right_modules[i].mod.*, rx, y);
        }
    }

    // === DRAW CENTER SECTION (truly centered, drawn last to win overlaps) ===
    if (center_width > 0) {
        // Use calculated center_start
        var cx: u16 = center_start;

        for (cfg.center) |mod| {
            if (std.mem.eql(u8, mod.name, "tabs")) {
                const active_style = shp.Style.parse(mod.active_style);
                const inactive_style = shp.Style.parse(mod.inactive_style);
                const sep_style = shp.Style.parse(mod.separator_style);

                for (ctx.tab_names, 0..) |tab_name, ti| {
                    // Stop at terminal edge
                    if (cx >= width) break;

                    if (ti > 0) {
                        cx = drawStyledText(renderer, cx, y, mod.separator, sep_style);
                        if (cx >= width) break;
                    }
                    const is_active = ti == ctx.active_tab;
                    const style = if (is_active) active_style else inactive_style;
                    const arrow_fg = if (is_active) active_style.bg else inactive_style.bg;
                    const arrow_style = shp.Style{ .fg = arrow_fg };

                    cx = drawStyledText(renderer, cx, y, tabs_left_arrow, arrow_style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, tab_name, style);
                    cx = drawStyledText(renderer, cx, y, " ", style);
                    cx = drawStyledText(renderer, cx, y, tabs_right_arrow, arrow_style);
                }
            }
        }
    }
}

/// If the mouse click at (x,y) hits a tab in the center tabs widget,
/// return the tab index.
pub fn hitTestTab(
    allocator: std.mem.Allocator,
    config: *const core.Config,
    term_width: u16,
    term_height: u16,
    tabs: anytype,
    active_tab: usize,
    session_name: []const u8,
    x: u16,
    y: u16,
) ?usize {
    if (!config.tabs.status.enabled) return null;
    if (term_height == 0) return null;
    const bar_y = term_height - 1;
    if (y != bar_y) return null;

    const width = term_width;
    const cfg = &config.tabs.status;

    // Create shp context for tab name resolution.
    var ctx = shp.Context.init(allocator);
    defer ctx.deinit();
    ctx.terminal_width = width;

    // Find the tabs module and its tab_title setting.
    var use_basename = true;
    var tabs_mod: ?*const core.Segment = null;
    for (cfg.center) |mod| {
        if (std.mem.eql(u8, mod.name, "tabs")) {
            use_basename = std.mem.eql(u8, mod.tab_title, "basename");
            tabs_mod = &mod;
            break;
        }
    }
    if (tabs_mod == null) return null;

    var tab_names: [16][]const u8 = undefined;
    var tab_count: usize = 0;
    for (tabs.items) |*tab| {
        if (tab_count >= tab_names.len) break;
        if (use_basename) {
            if (tab.layout.getFocusedPane()) |pane| {
                const pwd = pane.getRealCwd();
                tab_names[tab_count] = if (pwd) |p| blk: {
                    const base = std.fs.path.basename(p);
                    break :blk if (base.len == 0) "/" else base;
                } else tab.name;
            } else {
                tab_names[tab_count] = tab.name;
            }
        } else {
            tab_names[tab_count] = tab.name;
        }
        tab_count += 1;
    }
    if (tab_count == 0) return null;

    ctx.tab_names = tab_names[0..tab_count];
    ctx.active_tab = active_tab;
    ctx.session_name = session_name;

    const mod = tabs_mod.?;
    const center_width = measureTabsWidth(ctx.tab_names, mod.separator, mod.left_arrow, mod.right_arrow);
    if (center_width == 0) return null;
    const center_start = (width -| center_width) / 2;

    var cx: u16 = center_start;
    const left_arrow_width = measureText(mod.left_arrow);
    const right_arrow_width = measureText(mod.right_arrow);
    const sep_width = measureText(mod.separator);

    for (ctx.tab_names, 0..) |tab_name, ti| {
        if (ti > 0) {
            cx +|= sep_width;
        }
        const start_x = cx;
        cx +|= left_arrow_width;
        cx +|= 1;
        cx +|= measureText(tab_name);
        cx +|= 1;
        cx +|= right_arrow_width;
        const end_x = cx;

        if (x >= start_x and x < end_x) {
            return ti;
        }
    }

    return null;
}

// Helper to measure tabs width - mirrors exact rendering logic
fn measureTabsWidth(tab_names: []const []const u8, separator: []const u8, left_arrow: []const u8, right_arrow: []const u8) u16 {
    var w: u16 = 0;
    const left_arrow_width = measureText(left_arrow);
    const right_arrow_width = measureText(right_arrow);

    for (tab_names, 0..) |tab_name, ti| {
        if (ti > 0) w += measureText(separator);
        w += left_arrow_width;
        w += 1; // space
        w += measureText(tab_name);
        w += 1; // space
        w += right_arrow_width;
    }
    return w;
}

pub fn drawModule(renderer: *Renderer, ctx: *shp.Context, query: *const core.PaneQuery, mod: core.config.Segment, start_x: u16, y: u16) u16 {
    var x = start_x;

    if (!passesWhen(ctx, query, mod)) return x;

    for (mod.outputs) |out| {
        const style = shp.Style.parse(out.style);
        ctx.module_default_style = style;

        var output_segs: ?[]const shp.Segment = null;
        var output_text: []const u8 = "";
        if (std.mem.eql(u8, mod.name, "session")) {
            output_text = ctx.session_name;
        } else if (std.mem.eql(u8, mod.name, "randomdo")) {
            output_text = randomdoTextFor(ctx, mod, true);
        } else if (std.mem.eql(u8, mod.name, "spinner")) {
            if (mod.spinner) |cfg_in| {
                var cfg = cfg_in;
                cfg.started_at_ms = ctx.shell_started_at_ms orelse ctx.now_ms;
                output_segs = animations.renderSegments(ctx, cfg);
            }
        } else {
            output_segs = ctx.renderSegment(mod.name);
        }
        x = drawFormatted(renderer, x, y, out.format, output_text, output_segs, style);
    }

    return x;
}

pub fn drawFormatted(renderer: *Renderer, start_x: u16, y: u16, format: []const u8, output: []const u8, output_segs: ?[]const shp.Segment, style: shp.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            if (output_segs) |segs| {
                for (segs) |seg| {
                    x = drawSegment(renderer, x, y, seg, style);
                }
            } else {
                x = drawStyledText(renderer, x, y, output, style);
            }
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + len, format.len);
            x = drawStyledText(renderer, x, y, format[i..end], style);
            i = end;
        }
    }
    return x;
}

pub fn calcModuleWidth(ctx: *shp.Context, query: *const core.PaneQuery, mod: core.config.Segment) u16 {
    if (!passesWhen(ctx, query, mod)) return 0;
    var width: u16 = 0;

    for (mod.outputs) |out| {
        const style = shp.Style.parse(out.style);
        ctx.module_default_style = style;

        var output_segs: ?[]const shp.Segment = null;
        var output_text: []const u8 = "";
        if (std.mem.eql(u8, mod.name, "session")) {
            output_text = ctx.session_name;
        } else if (std.mem.eql(u8, mod.name, "randomdo")) {
            width += calcFormattedWidthMax(out.format, randomdo_mod.MAX_LEN);
            continue;
        } else if (std.mem.eql(u8, mod.name, "spinner")) {
            if (mod.spinner) |cfg_in| {
                var cfg = cfg_in;
                cfg.started_at_ms = ctx.shell_started_at_ms orelse ctx.now_ms;
                output_segs = animations.renderSegments(ctx, cfg);
            }
        } else {
            output_segs = ctx.renderSegment(mod.name);
        }
        width += calcFormattedWidth(out.format, output_text, output_segs);
    }

    return width;
}

fn calcFormattedWidthMax(format: []const u8, output_max: u16) u16 {
    var width: u16 = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            width += output_max;
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            i += len;
            width += 1;
        }
    }
    return width;
}

pub fn countDisplayWidth(text: []const u8) u16 {
    return measureText(text);
}

// Measure text width in terminal cells (same logic as drawStyledText)
pub fn measureText(text: []const u8) u16 {
    var width: u16 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        i = end;
        width += 1;
    }
    return width;
}

pub fn calcFormattedWidth(format: []const u8, output: []const u8, output_segs: ?[]const shp.Segment) u16 {
    var width: u16 = 0;
    var i: usize = 0;

    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            if (output_segs) |segs| {
                for (segs) |seg| {
                    width += measureText(seg.text);
                }
            } else {
                width += measureText(output);
            }
            i += 7;
        } else {
            const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            i += len;
            width += 1;
        }
    }
    return width;
}

fn mergeStyle(base: shp.Style, override: shp.Style) shp.Style {
    var out = base;
    if (override.fg != .none) out.fg = override.fg;
    if (override.bg != .none) out.bg = override.bg;
    if (override.bold) out.bold = true;
    if (override.italic) out.italic = true;
    if (override.underline) out.underline = true;
    if (override.dim) out.dim = true;
    return out;
}

pub fn drawSegment(renderer: *Renderer, x: u16, y: u16, seg: shp.Segment, default_style: shp.Style) u16 {
    const style = if (seg.style.isEmpty()) default_style else mergeStyle(default_style, seg.style);
    return drawStyledText(renderer, x, y, seg.text, style);
}

pub fn drawStyledText(renderer: *Renderer, start_x: u16, y: u16, text: []const u8, style: shp.Style) u16 {
    var x = start_x;
    var i: usize = 0;

    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const codepoint = std.unicode.utf8Decode(text[i..][0..len]) catch ' ';

        var cell = render.Cell{
            .char = codepoint,
            .bold = style.bold,
            .italic = style.italic,
        };

        switch (style.fg) {
            .none => {},
            .palette => |p| cell.fg = .{ .palette = p },
            .rgb => |rgb| cell.fg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }
        switch (style.bg) {
            .none => {},
            .palette => |p| cell.bg = .{ .palette = p },
            .rgb => |rgb| cell.bg = .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        }

        renderer.setCell(x, y, cell);
        x += 1;
        i += len;
    }

    return x;
}
