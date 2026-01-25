const std = @import("std");
const posix = std.posix;
const core = @import("core");
const lua_runtime = core.lua_runtime;
const LuaRuntime = core.LuaRuntime;
const segment = core.segments;
const segments_mod = core.segments;
const Style = core.style.Style;

const bash_init = @import("shell/bash.zig");
const zsh_init = @import("shell/zsh.zig");
const fish_init = @import("shell/fish.zig");

// Config structures for Lua parsing
const OutputDef = struct {
    style: []const u8,
    format: []const u8,
};

const ModuleDef = struct {
    name: []const u8,
    priority: i64,
    outputs: []const OutputDef,
    command: ?[]const u8,
    when: ?core.WhenDef,
};

const ShpConfig = struct {
    left: []const ModuleDef,
    right: []const ModuleDef,
    has_config: bool,
};

/// Arguments for shp commands
pub const PopArgs = struct {
    init_shell: ?[]const u8 = null,
    no_comms: bool = false,
    prompt: bool = false,
    status: i64 = 0,
    duration: i64 = 0,
    right: bool = false,
    shell: ?[]const u8 = null,
    jobs: i64 = 0,

    // shell-event extended fields
    shell_phase: ?[]const u8 = null,
    shell_running: bool = false,
    shell_started_at: i64 = 0,
};

/// Entry point for shp - can be called directly from unified CLI
pub fn run(args: PopArgs) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (args.init_shell) |shell| {
        try printInit(shell, args.no_comms);
    } else if (args.prompt) {
        // Build args array for renderPrompt
        var prompt_args: [6][]const u8 = undefined;
        var argc: usize = 0;

        var status_buf: [32]u8 = undefined;
        var duration_buf: [32]u8 = undefined;
        var jobs_buf: [32]u8 = undefined;
        var shell_buf: [64]u8 = undefined;

        if (args.status != 0) {
            prompt_args[argc] = std.fmt.bufPrint(&status_buf, "--status={d}", .{args.status}) catch "--status=0";
            argc += 1;
        }
        if (args.duration != 0) {
            prompt_args[argc] = std.fmt.bufPrint(&duration_buf, "--duration={d}", .{args.duration}) catch "--duration=0";
            argc += 1;
        }
        if (args.right) {
            prompt_args[argc] = "--right";
            argc += 1;
        }
        if (args.shell) |shell| {
            prompt_args[argc] = std.fmt.bufPrint(&shell_buf, "--shell={s}", .{shell}) catch "--shell=bash";
            argc += 1;
        }
        if (args.jobs != 0) {
            prompt_args[argc] = std.fmt.bufPrint(&jobs_buf, "--jobs={d}", .{args.jobs}) catch "--jobs=0";
            argc += 1;
        }

        try renderPrompt(allocator, prompt_args[0..argc]);
    } else {
        try printUsage();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        // shp init <shell>
        const shell = if (args.len > 2) args[2] else "bash";
        try run(.{ .init_shell = shell });
    } else if (std.mem.eql(u8, command, "prompt")) {
        // shp prompt [options]
        try renderPrompt(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(
        \\shp - Shell prompt
        \\
        \\Usage:
        \\  shp init <shell>     Print shell initialization script
        \\  shp prompt [opts]    Render the prompt
        \\  shp help             Show this help
        \\
        \\Shell init:
        \\  shp init bash        Bash initialization
        \\  shp init zsh         Zsh initialization
        \\  shp init fish        Fish initialization
        \\
        \\Prompt options:
        \\  --status=<n>         Exit status of last command
        \\  --duration=<ms>      Duration of last command in ms
        \\  --jobs=<n>           Number of background jobs
        \\  --right              Render right prompt
        \\
    );
}

fn printInit(shell: []const u8, no_comms: bool) !void {
    const stdout = std.fs.File.stdout();

    if (std.mem.eql(u8, shell, "bash")) {
        try bash_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try zsh_init.printInit(stdout, no_comms);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try fish_init.printInit(stdout, no_comms);
    } else {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unknown shell: {s}\nSupported shells: bash, zsh, fish\n", .{shell}) catch return;
        try stdout.writeAll(msg);
    }
}

fn renderPrompt(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var ctx = segment.Context.init(allocator);
    defer ctx.deinit();

    // Parse command line options
    var is_right = false;
    var shell: []const u8 = "bash";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--right")) {
            is_right = true;
        } else if (std.mem.startsWith(u8, arg, "--status=")) {
            ctx.exit_status = std.fmt.parseInt(i32, arg[9..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--duration=")) {
            ctx.cmd_duration_ms = std.fmt.parseInt(u64, arg[11..], 10) catch null;
        } else if (std.mem.startsWith(u8, arg, "--jobs=")) {
            ctx.jobs = std.fmt.parseInt(u16, arg[7..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--shell=")) {
            shell = arg[8..];
        }
    }

    // Get environment info
    ctx.cwd = std.posix.getenv("PWD") orelse "";
    ctx.home = std.posix.getenv("HOME");
    ctx.now_ms = @intCast(std.time.milliTimestamp());

    // Get terminal width from COLUMNS env var or default
    if (posix.getenv("COLUMNS")) |cols| {
        ctx.terminal_width = std.fmt.parseInt(u16, cols, 10) catch 80;
    }

    const stdout = std.fs.File.stdout();

    // Detect shell from environment if not specified
    if (std.mem.eql(u8, shell, "bash")) {
        // Try to auto-detect from $SHELL or $0
        if (posix.getenv("ZSH_VERSION")) |_| {
            shell = "zsh";
        } else if (posix.getenv("FISH_VERSION")) |_| {
            shell = "fish";
        }
    }

    const is_zsh = std.mem.eql(u8, shell, "zsh");

    // Try to load config
    var config = loadConfig(allocator);
    defer deinitShpConfig(&config, allocator);

    if (config.has_config) {
        const modules = if (is_right) config.right else config.left;
        if (modules.len > 0) {
            try renderModulesSimple(&ctx, modules, stdout, is_zsh);
            return;
        }
    }

    // Fallback to defaults if no config
    try renderDefaultPrompt(&ctx, is_right, stdout);
}

fn deinitShpConfig(config: *ShpConfig, allocator: std.mem.Allocator) void {
    if (!config.has_config) return;
    deinitModules(config.left, allocator);
    deinitModules(config.right, allocator);
    if (config.left.len > 0) allocator.free(config.left);
    if (config.right.len > 0) allocator.free(config.right);
    config.* = .{ .left = &[_]ModuleDef{}, .right = &[_]ModuleDef{}, .has_config = false };
}

fn deinitModules(mods: []const ModuleDef, allocator: std.mem.Allocator) void {
    for (mods) |m| {
        allocator.free(m.name);
        if (m.command) |c| allocator.free(c);
        if (m.when) |w| {
            var ww = w;
            ww.deinit(allocator);
        }
        for (m.outputs) |o| {
            allocator.free(o.style);
            allocator.free(o.format);
        }
        if (m.outputs.len > 0) allocator.free(m.outputs);
    }
}

fn renderDefaultPrompt(ctx: *segment.Context, is_right: bool, stdout: std.fs.File) !void {
    const segment_names: []const []const u8 = if (is_right)
        &.{"time"}
    else
        &.{ "directory", "git_branch", "git_status", "character" };

    for (segment_names) |name| {
        if (ctx.renderSegment(name)) |segs| {
            for (segs) |seg| {
                // Just write text directly - no styling for now
                try stdout.writeAll(seg.text);
                try stdout.writeAll(" ");
            }
        }
    }
}

fn evalLuaWhen(runtime: *LuaRuntime, ctx: *segment.Context, code: []const u8) bool {
    // Provide ctx as a global table.
    runtime.lua.createTable(0, 6);
    _ = runtime.lua.pushString(ctx.cwd);
    runtime.lua.setField(-2, "cwd");

    if (ctx.exit_status) |st| {
        runtime.lua.pushInteger(st);
        runtime.lua.setField(-2, "exit_status");
    }
    if (ctx.cmd_duration_ms) |d| {
        runtime.lua.pushInteger(@intCast(d));
        runtime.lua.setField(-2, "cmd_duration_ms");
    }
    runtime.lua.pushInteger(ctx.jobs);
    runtime.lua.setField(-2, "jobs");
    runtime.lua.pushInteger(ctx.terminal_width);
    runtime.lua.setField(-2, "terminal_width");
    runtime.lua.setGlobal("ctx");

    const code_z = runtime.allocator.dupeZ(u8, code) catch return false;
    defer runtime.allocator.free(code_z);

    // Load and execute chunk. Must return boolean.
    runtime.lua.loadString(code_z) catch return false;
    runtime.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        runtime.lua.pop(1);
        return false;
    };
    defer runtime.lua.pop(1);

    if (runtime.lua.typeOf(-1) == .boolean) {
        return runtime.lua.toBoolean(-1);
    }
    return false;
}

fn evalPromptWhen(allocator: std.mem.Allocator, lua_rt: *?LuaRuntime, ctx: *segment.Context, when: core.WhenDef) bool {
    if (when.any) |clauses| {
        for (clauses) |c| {
            if (evalPromptWhenClause(allocator, lua_rt, ctx, c)) return true;
        }
        return false;
    }
    return evalPromptWhenClause(allocator, lua_rt, ctx, when);
}

fn evalPromptWhenClause(allocator: std.mem.Allocator, lua_rt: *?LuaRuntime, ctx: *segment.Context, when: core.WhenDef) bool {
    if (when.lua) |lua_code| {
        if (lua_rt.* == null) {
            lua_rt.* = LuaRuntime.init(allocator) catch null;
        }
        if (lua_rt.* == null) return false;
        if (!evalLuaWhen(&lua_rt.*.?, ctx, lua_code)) return false;
    }

    if (when.bash) |bash_code| {
        const res = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "/bin/bash", "-lc", bash_code },
        }) catch return false;
        allocator.free(res.stdout);
        allocator.free(res.stderr);
        const ok = switch (res.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!ok) return false;
    }

    return true;
}

fn loadConfig(allocator: std.mem.Allocator) ShpConfig {
    var config = ShpConfig{
        .left = &[_]ModuleDef{},
        .right = &[_]ModuleDef{},
        .has_config = false,
    };

    const path = lua_runtime.getConfigPath(allocator, "config.lua") catch return config;
    defer allocator.free(path);

    var runtime = LuaRuntime.init(allocator) catch {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("shp: failed to initialize Lua\n") catch {};
        return config;
    };
    defer runtime.deinit();

    runtime.setHexeSection("shp");

    runtime.loadConfig(path) catch |err| {
        switch (err) {
            error.FileNotFound => {
                // Silent - missing config is fine
            },
            else => {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("shp: config error") catch {};
                if (runtime.last_error) |msg| {
                    stderr.writeAll(": ") catch {};
                    stderr.writeAll(msg) catch {};
                }
                stderr.writeAll("\n") catch {};
            },
        }
        return config;
    };

    // Access the "shp" section of the config table
    if (!runtime.pushTable(-1, "shp")) {
        return config;
    }
    defer runtime.pop();

    config.has_config = true;

    // Parse prompt.left and prompt.right
    if (runtime.pushTable(-1, "prompt")) {
        config.left = parseModules(&runtime, allocator, "left");
        config.right = parseModules(&runtime, allocator, "right");
        runtime.pop();
    }

    return config;
}

fn parseModules(runtime: *LuaRuntime, allocator: std.mem.Allocator, key: [:0]const u8) []const ModuleDef {
    if (!runtime.pushTable(-1, key)) {
        return &[_]ModuleDef{};
    }
    defer runtime.pop();

    var list = std.ArrayList(ModuleDef).empty;
    const len = runtime.getArrayLen(-1);

    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            if (parseModule(runtime, allocator)) |mod| {
                list.append(allocator, mod) catch {};
            }
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]ModuleDef{};
}

fn parseModule(runtime: *LuaRuntime, allocator: std.mem.Allocator) ?ModuleDef {
    const name = runtime.getStringAlloc(-1, "name") orelse return null;

    const when_ty = runtime.fieldType(-1, "when");
    if (when_ty != .nil and when_ty != .table) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("shp: module 'when' must be a table\n") catch {};
        allocator.free(name);
        return null;
    }

    return ModuleDef{
        .name = name,
        .priority = runtime.getInt(i64, -1, "priority") orelse 50,
        .outputs = parseOutputs(runtime, allocator),
        .command = runtime.getStringAlloc(-1, "command"),
        .when = parseWhenPrompt(runtime),
    };
}

fn parseWhenPrompt(runtime: *LuaRuntime) ?core.WhenDef {
    const ty = runtime.fieldType(-1, "when");
    if (ty == .nil) return null;
    if (ty != .table) return null;

    if (!runtime.pushTable(-1, "when")) return null;
    defer runtime.pop();

    // Strict: prompt does not allow hexe.* providers.
    if (runtime.fieldType(-1, "hexe") != .nil or
        runtime.fieldType(-1, "hexe.shp") != .nil or
        runtime.fieldType(-1, "hexe.mux") != .nil or
        runtime.fieldType(-1, "hexe.ses") != .nil or
        runtime.fieldType(-1, "hexe.pod") != .nil)
    {
        return null;
    }

    var when: core.WhenDef = .{};
    when.bash = runtime.getStringAlloc(-1, "bash");
    when.lua = runtime.getStringAlloc(-1, "lua");
    return when;
}

fn parseOutputs(runtime: *LuaRuntime, allocator: std.mem.Allocator) []const OutputDef {
    if (!runtime.pushTable(-1, "outputs")) {
        return &[_]OutputDef{};
    }
    defer runtime.pop();

    var list = std.ArrayList(OutputDef).empty;
    const len = runtime.getArrayLen(-1);

    for (1..len + 1) |i| {
        if (runtime.pushArrayElement(-1, i)) {
            const style = if (runtime.getString(-1, "style")) |s|
                allocator.dupe(u8, s) catch {
                    runtime.pop();
                    continue;
                }
            else
                allocator.dupe(u8, "") catch {
                    runtime.pop();
                    continue;
                };

            const format = if (runtime.getString(-1, "format")) |s|
                allocator.dupe(u8, s) catch {
                    allocator.free(style);
                    runtime.pop();
                    continue;
                }
            else
                allocator.dupe(u8, "$output") catch {
                    allocator.free(style);
                    runtime.pop();
                    continue;
                };

            list.append(allocator, .{ .style = style, .format = format }) catch {
                allocator.free(style);
                allocator.free(format);
            };
            runtime.pop();
        }
    }

    return list.toOwnedSlice(allocator) catch &[_]OutputDef{};
}

fn renderModulesSimple(ctx: *segment.Context, modules: []const ModuleDef, stdout: std.fs.File, is_zsh: bool) !void {
    const alloc = std.heap.page_allocator;

    // Known built-in segments that return null when they have nothing to show
    const conditional_segments = [_][]const u8{ "status", "sudo", "git_branch", "git_status", "jobs", "duration" };

    const ModuleResult = struct {
        when_passed: bool = true,
        when_lua_passed: bool = true,
        output: ?[]const u8 = null,
        width: u16 = 0,
        should_render: bool = true,
        visible: bool = true, // After priority filtering
    };

    var results: [32]ModuleResult = [_]ModuleResult{.{}} ** 32;
    const mod_count = @min(modules.len, 32);

    // Evaluate all `when` on the main thread.
    // This avoids Lua VM thread-safety issues and keeps semantics simple.
    var lua_rt: ?LuaRuntime = null;
    defer if (lua_rt) |*rt| rt.deinit();

    for (modules[0..mod_count], 0..) |mod, i| {
        if (mod.when) |w| {
            results[i].when_passed = evalPromptWhen(alloc, &lua_rt, ctx, w);
        }
    }

    // Thread function for running a module's commands
    const ThreadContext = struct {
        mod: *const ModuleDef,
        result: *ModuleResult,
        alloc: std.mem.Allocator,
    };

    const thread_fn = struct {
        fn run(tctx: ThreadContext) void {
            if (!tctx.result.when_passed) return;

            // Run command
            if (tctx.mod.command) |cmd| {
                const cmd_result = std.process.Child.run(.{
                    .allocator = tctx.alloc,
                    .argv = &.{ "/bin/bash", "-c", cmd },
                }) catch return;
                tctx.alloc.free(cmd_result.stderr);

                const exit_ok = switch (cmd_result.term) {
                    .Exited => |code| code == 0,
                    else => false,
                };
                if (!exit_ok) {
                    tctx.alloc.free(cmd_result.stdout);
                    return;
                }

                const trimmed = std.mem.trimRight(u8, cmd_result.stdout, "\n\r");
                if (trimmed.len > 0) {
                    tctx.result.output = trimmed;
                } else {
                    tctx.alloc.free(cmd_result.stdout);
                }
            }
        }
    }.run;

    // Spawn threads for modules with commands or when conditions
    var threads: [32]?std.Thread = [_]?std.Thread{null} ** 32;
    for (modules[0..mod_count], 0..) |*mod, i| {
        if (mod.when != null or mod.command != null) {
            threads[i] = std.Thread.spawn(.{}, thread_fn, .{ThreadContext{
                .mod = mod,
                .result = &results[i],
                .alloc = alloc,
            }}) catch null;
        }
    }

    // Wait for all threads
    for (threads[0..mod_count]) |maybe_thread| {
        if (maybe_thread) |thread| {
            thread.join();
        }
    }

    // First pass: calculate output text, width, and should_render for each module
    for (modules[0..mod_count], 0..) |mod, i| {
        if (!results[i].when_passed) {
            results[i].should_render = false;
            continue;
        }

        var output_text: []const u8 = "";

        if (mod.command != null) {
            if (results[i].output) |out| {
                output_text = out;
            } else {
                results[i].should_render = false;
                continue;
            }
        } else {
            var is_conditional = false;
            for (conditional_segments) |cs| {
                if (std.mem.eql(u8, mod.name, cs)) {
                    is_conditional = true;
                    break;
                }
            }

            if (ctx.renderSegment(mod.name)) |segs| {
                if (segs.len > 0) {
                    output_text = segs[0].text;
                }
            } else if (is_conditional) {
                results[i].should_render = false;
                continue;
            }
        }

        // Store output for later rendering
        results[i].output = output_text;

        // Calculate width from outputs
        for (mod.outputs) |out| {
            results[i].width += calcFormatWidth(out.format, output_text);
        }
    }

    // Priority-based width filtering
    // Use half terminal width as budget (left/right prompts share the space)
    const width_budget = ctx.terminal_width / 2;
    var used_width: u16 = 0;

    // Create sorted index array by priority (lower priority number = higher importance)
    var priority_order: [32]usize = undefined;
    for (0..mod_count) |i| {
        priority_order[i] = i;
    }

    // Sort by priority (insertion sort - small array)
    for (1..mod_count) |i| {
        const key = priority_order[i];
        const key_priority = modules[key].priority;
        var j: usize = i;
        while (j > 0) {
            const prev_priority = modules[priority_order[j - 1]].priority;
            if (prev_priority <= key_priority) break;
            priority_order[j] = priority_order[j - 1];
            j -= 1;
        }
        priority_order[j] = key;
    }

    // Mark modules as visible based on priority until budget exhausted
    for (priority_order[0..mod_count]) |idx| {
        if (!results[idx].should_render) continue;
        if (used_width + results[idx].width <= width_budget) {
            results[idx].visible = true;
            used_width += results[idx].width;
        } else {
            results[idx].visible = false;
        }
    }

    // Render modules in original order, but only visible ones
    for (modules[0..mod_count], 0..) |mod, i| {
        if (!results[i].should_render or !results[i].visible) continue;

        const output_text = results[i].output orelse "";

        for (mod.outputs) |out| {
            const style = Style.parse(out.style);

            try writeStyleDirect(stdout, style, is_zsh);
            try writeFormat(stdout, out.format, output_text);

            if (!style.isEmpty()) {
                if (is_zsh) try stdout.writeAll("%{");
                try stdout.writeAll("\x1b[0m");
                if (is_zsh) try stdout.writeAll("%}");
            }
        }
    }
}

/// Calculate the visible width of a format string with $output substituted
fn calcFormatWidth(format: []const u8, output: []const u8) u16 {
    var width: u16 = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (i + 6 < format.len and std.mem.eql(u8, format[i .. i + 7], "$output")) {
            width += @intCast(output.len);
            i += 7;
        } else {
            width += 1;
            i += 1;
        }
    }
    return width;
}

fn writeStyleDirect(stdout: std.fs.File, style: Style, is_zsh: bool) !void {
    if (style.isEmpty()) return;

    if (is_zsh) try stdout.writeAll("%{");

    // Build ANSI sequence
    var buf: [64]u8 = undefined;
    var len: usize = 0;

    buf[0] = '\x1b';
    buf[1] = '[';
    len = 2;

    var need_semi = false;

    if (style.bold) {
        buf[len] = '1';
        len += 1;
        need_semi = true;
    }
    if (style.dim) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '2';
        len += 1;
        need_semi = true;
    }
    if (style.italic) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '3';
        len += 1;
        need_semi = true;
    }
    if (style.underline) {
        if (need_semi) {
            buf[len] = ';';
            len += 1;
        }
        buf[len] = '4';
        len += 1;
        need_semi = true;
    }

    // Foreground color
    switch (style.fg) {
        .none => {},
        .palette => |p| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = if (p < 8)
                std.fmt.bufPrint(buf[len..], "{d}", .{30 + p}) catch ""
            else if (p < 16)
                std.fmt.bufPrint(buf[len..], "{d}", .{90 + p - 8}) catch ""
            else
                std.fmt.bufPrint(buf[len..], "38;5;{d}", .{p}) catch "";
            len += code.len;
            need_semi = true;
        },
        .rgb => |rgb| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = std.fmt.bufPrint(buf[len..], "38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
            len += code.len;
            need_semi = true;
        },
    }

    // Background color
    switch (style.bg) {
        .none => {},
        .palette => |p| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = if (p < 8)
                std.fmt.bufPrint(buf[len..], "{d}", .{40 + p}) catch ""
            else if (p < 16)
                std.fmt.bufPrint(buf[len..], "{d}", .{100 + p - 8}) catch ""
            else
                std.fmt.bufPrint(buf[len..], "48;5;{d}", .{p}) catch "";
            len += code.len;
        },
        .rgb => |rgb| {
            if (need_semi) {
                buf[len] = ';';
                len += 1;
            }
            const code = std.fmt.bufPrint(buf[len..], "48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }) catch "";
            len += code.len;
        },
    }

    buf[len] = 'm';
    len += 1;

    try stdout.writeAll(buf[0..len]);
    if (is_zsh) try stdout.writeAll("%}");
}

fn writeFormat(stdout: std.fs.File, format: []const u8, output: []const u8) !void {
    var i: usize = 0;
    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            try stdout.writeAll(output);
            i += 7;
        } else {
            const char_len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
            const end = @min(i + char_len, format.len);
            try stdout.writeAll(format[i..end]);
            i = end;
        }
    }
}

