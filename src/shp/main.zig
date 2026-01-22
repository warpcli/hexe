const std = @import("std");
const posix = std.posix;
const core = @import("core");
const lua_runtime = core.lua_runtime;
const LuaRuntime = core.LuaRuntime;
const segment = @import("segment.zig");
const segments_mod = @import("segments/mod.zig");
const Style = @import("style.zig").Style;

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
    when: ?[]const u8,
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
        try stdout.writeAll(
            \\# Hexe prompt initialization for Bash
            \\__shp_precmd() {
            \\    local exit_status=$?
            \\    local duration=0
            \\    if [[ -n "$__shp_start" ]]; then
            \\        duration=$(( $(date +%s%3N) - __shp_start ))
            \\    fi
            \\    PS1="$(hexe shp prompt --status=$exit_status --duration=$duration --jobs=$(jobs -p 2>/dev/null | wc -l)) "
            \\    unset __shp_start
            \\}
            \\
            \\__shp_preexec() {
            \\    __shp_start=$(date +%s%3N)
            \\}
            \\
            \\trap '__shp_preexec' DEBUG
            \\PROMPT_COMMAND="__shp_precmd"
            \\
        );

        if (!no_comms) {
            try stdout.writeAll(
                \\# Hexe shell->mux communication hooks (Bash)
                \\__hexe_exit_intent() {
                \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || return 0
                \\    hexe com exit-intent >/dev/null 2>/dev/null
                \\    return $?
                \\}
                \\
                \\__hexe_preexec() {
                \\    __hexe_start=$(date +%s%3N)
                \\}
                \\
                \\__hexe_precmd() {
                \\    local exit_status=$?
                \\    local duration=0
                \\    if [[ -n "$__hexe_start" ]]; then
                \\        duration=$(( $(date +%s%3N) - __hexe_start ))
                \\    fi
                \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || { unset __hexe_start; return 0; }
                \\    # OSC 7 cwd sync
                \\    printf '\033]7;file://%s%s\007' "${HOSTNAME:-localhost}" "$PWD" 2>/dev/null
                \\    local hist="$(history 1 2>/dev/null)"
                \\    local cmd="$hist"
                \\    if [[ $hist =~ ^[[:space:]]*[0-9]+[[:space:]]*(.*)$ ]]; then
                \\        cmd="${BASH_REMATCH[1]}"
                \\    fi
                \\    local jobs_count=$(jobs -p 2>/dev/null | wc -l)
                \\    hexe com shell-event --cmd="$cmd" --status=$exit_status --duration=$duration --cwd="$PWD" --jobs=$jobs_count >/dev/null 2>/dev/null
                \\    unset __hexe_start
                \\}
                \\
                \\exit() {
                \\    case $- in *i*) ;; *) builtin exit "$@" ;; esac
                \\    __hexe_exit_intent || return 0
                \\    builtin exit "$@"
                \\}
                \\
                \\logout() {
                \\    case $- in *i*) ;; *) builtin logout "$@" ;; esac
                \\    __hexe_exit_intent || return 0
                \\    builtin logout "$@"
                \\}
                \\
                \\__hexe_ctrl_d() {
                \\    if [[ -z "$READLINE_LINE" ]]; then
                \\        __hexe_exit_intent || { READLINE_LINE=""; READLINE_POINT=0; return; }
                \\        builtin exit
                \\    fi
                \\}
                \\
                \\bind -x '"\C-d":__hexe_ctrl_d'
                \\
                \\# Extend existing timing hooks with comms.
                \\PROMPT_COMMAND="__shp_precmd;__hexe_precmd"
                \\trap '__shp_preexec;__hexe_preexec' DEBUG
                \\
            );
        }
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try stdout.writeAll(
            \\# Hexe prompt initialization for Zsh
            \\__shp_precmd() {
            \\    local exit_status=$?
            \\    local duration=0
            \\    if [[ -n "$__shp_start" ]]; then
            \\        duration=$(( $(date +%s%3N) - __shp_start ))
            \\    fi
            \\    PROMPT="$(hexe shp prompt --shell=zsh --status=$exit_status --duration=$duration --jobs=${(M)#jobstates}) "
            \\    RPROMPT="$(hexe shp prompt --shell=zsh --right --status=$exit_status)"
            \\    unset __shp_start
            \\}
            \\
            \\__shp_preexec() {
            \\    __shp_start=$(date +%s%3N)
            \\}
            \\
            \\autoload -Uz add-zsh-hook
            \\add-zsh-hook precmd __shp_precmd
            \\add-zsh-hook preexec __shp_preexec
            \\ZLE_RPROMPT_INDENT=0
            \\
        );

        if (!no_comms) {
            try stdout.writeAll(
                \\# Hexe shell->mux communication hooks (Zsh)
                \\__hexe_last_cmd=""
                \\__hexe_start=""
                \\
                \\__hexe_exit_intent() {
                \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || return 0
                \\    hexe com exit-intent >/dev/null 2>/dev/null
                \\    return $?
                \\}
                \\
                \\__hexe_preexec_capture() {
                \\    __hexe_last_cmd="$1"
                \\    __hexe_start=$(date +%s%3N)
                \\}
                \\
                \\__hexe_precmd_send() {
                \\    local exit_status=$?
                \\    local duration=0
                \\    if [[ -n "$__hexe_start" ]]; then
                \\        duration=$(( $(date +%s%3N) - __hexe_start ))
                \\    fi
                \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || { unset __hexe_start; return 0; }
                \\    # OSC 7 cwd sync
                \\    printf '\033]7;file://%s%s\007' "${HOST:-localhost}" "$PWD" 2>/dev/null
                \\    hexe com shell-event --cmd="$__hexe_last_cmd" --status=$exit_status --duration=$duration --cwd="$PWD" --jobs=${(M)#jobstates} >/dev/null 2>/dev/null
                \\    unset __hexe_start
                \\}
                \\
                \\__hexe_accept_line() {
                \\    if [[ "$BUFFER" == "exit" || "$BUFFER" == "logout" ]]; then
                \\        __hexe_exit_intent || { BUFFER=""; zle reset-prompt; return 0; }
                \\    fi
                \\    zle .accept-line
                \\}
                \\zle -N accept-line __hexe_accept_line
                \\
                \\__hexe_ctrl_d() {
                \\    if [[ -z "$BUFFER" ]]; then
                \\        __hexe_exit_intent || { BUFFER=""; zle reset-prompt; return 0; }
                \\        zle .send-eof
                \\        return
                \\    fi
                \\    zle .delete-char
                \\}
                \\zle -N __hexe_ctrl_d
                \\bindkey '^D' __hexe_ctrl_d
                \\
                \\autoload -Uz add-zsh-hook
                \\add-zsh-hook preexec __hexe_preexec_capture
                \\add-zsh-hook precmd __hexe_precmd_send
                \\
            );
        }
    } else if (std.mem.eql(u8, shell, "fish")) {
        try stdout.writeAll(
            \\# Hexe prompt initialization for Fish
            \\function fish_prompt
            \\    set -l exit_status $status
            \\    set -l duration (math $CMD_DURATION)
            \\    set -l jobs (count (jobs -p))
            \\    hexe shp prompt --status=$exit_status --duration=$duration --jobs=$jobs
            \\    echo -n " "
            \\end
            \\
            \\function fish_right_prompt
            \\    hexe shp prompt --right
            \\end
            \\
        );

        if (!no_comms) {
            try stdout.writeAll(
                \\# Hexe shell->mux communication hooks (Fish)
                \\function __hexe_exit_intent
                \\    if not status is-interactive
                \\        return 0
                \\    end
                \\    if not set -q HEXE_MUX_SOCKET
                \\        return 0
                \\    end
                \\    if not set -q HEXE_PANE_UUID
                \\        return 0
                \\    end
                \\    hexe com exit-intent >/dev/null 2>/dev/null
                \\    return $status
                \\end
                \\
                \\function exit
                \\    __hexe_exit_intent; or return 0
                \\    builtin exit $argv
                \\end
                \\
                \\function logout
                \\    exit $argv
                \\end
                \\
                \\function __hexe_ctrl_d
                \\    set -l line (commandline)
                \\    if test -z "$line"
                \\        __hexe_exit_intent; or begin
                \\            commandline ""
                \\            commandline -f repaint
                \\            return
                \\        end
                \\        exit
                \\    end
                \\    commandline -f delete-char
                \\end
                \\bind \cd __hexe_ctrl_d
                \\
                \\function __hexe_fish_postexec --on-event fish_postexec
                \\    if not status is-interactive
                \\        return
                \\    end
                \\    if not set -q HEXE_MUX_SOCKET
                \\        return
                \\    end
                \\    if not set -q HEXE_PANE_UUID
                \\        return
                \\    end
                \\    set -l cmdline (string join " " -- $argv)
                \\    # OSC 7 cwd sync
                \\    printf '\033]7;file://%s%s\007' "$hostname" "$PWD" 2>/dev/null
                \\    set -l jobs_count (count (jobs -p))
                \\    hexe com shell-event --cmd="$cmdline" --status=$status --duration=$CMD_DURATION --cwd="$PWD" --jobs=$jobs_count >/dev/null 2>/dev/null
                \\end
                \\
            );
        }
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
    const config = loadConfig(allocator);

    if (config.has_config) {
        const modules = if (is_right) config.right else config.left;
        if (modules.len > 0) {
            try renderModulesSimple(&ctx, modules, stdout, is_zsh);
            return;
        }
    }

    // Fallback to defaults if no config
    try renderDefaultPrompt(&ctx, is_right, stdout, is_zsh);
}

fn renderDefaultPrompt(ctx: *segment.Context, is_right: bool, stdout: std.fs.File, is_zsh: bool) !void {
    _ = is_zsh;
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

fn writeSegment(stdout: std.fs.File, seg: segment.Segment, is_zsh: bool) !void {
    try writeStyleDirect(stdout, seg.style, is_zsh);
    try stdout.writeAll(seg.text);
    if (!seg.style.isEmpty()) {
        if (is_zsh) try stdout.writeAll("%{");
        try stdout.writeAll("\x1b[0m");
        if (is_zsh) try stdout.writeAll("%}");
    }
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

    return ModuleDef{
        .name = name,
        .priority = runtime.getInt(i64, -1, "priority") orelse 50,
        .outputs = parseOutputs(runtime, allocator),
        .command = runtime.getStringAlloc(-1, "command"),
        .when = runtime.getStringAlloc(-1, "when"),
    };
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
            list.append(allocator, .{
                .style = runtime.getStringAlloc(-1, "style") orelse "",
                .format = runtime.getStringAlloc(-1, "format") orelse "$output",
            }) catch {};
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
        output: ?[]const u8 = null,
        width: u16 = 0,
        should_render: bool = true,
        visible: bool = true, // After priority filtering
    };

    var results: [32]ModuleResult = [_]ModuleResult{.{}} ** 32;
    const mod_count = @min(modules.len, 32);

    // Thread function for running a module's commands
    const ThreadContext = struct {
        mod: *const ModuleDef,
        result: *ModuleResult,
        alloc: std.mem.Allocator,
    };

    const thread_fn = struct {
        fn run(tctx: ThreadContext) void {
            // Check 'when' condition
            if (tctx.mod.when) |when_cmd| {
                const when_result = std.process.Child.run(.{
                    .allocator = tctx.alloc,
                    .argv = &.{ "/bin/bash", "-c", when_cmd },
                }) catch {
                    tctx.result.when_passed = false;
                    return;
                };
                tctx.alloc.free(when_result.stdout);
                tctx.alloc.free(when_result.stderr);
                tctx.result.when_passed = switch (when_result.term) {
                    .Exited => |code| code == 0,
                    else => false,
                };
                if (!tctx.result.when_passed) return;
            }

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

fn runCommand(allocator: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
    _ = allocator;
    // Use page_allocator - prompt is short-lived, OS will reclaim
    const alloc = std.heap.page_allocator;
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/bash", "-c", cmd },
    }) catch return null;
    alloc.free(result.stderr);

    // Check if command exited successfully
    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };
    if (exit_code != 0) {
        alloc.free(result.stdout);
        return null;
    }

    // Trim trailing newline
    const output = std.mem.trimRight(u8, result.stdout, "\n\r");
    if (output.len == 0) {
        alloc.free(result.stdout);
        return null;
    }

    return output;
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

fn checkCondition(cmd: []const u8) bool {
    // Use bash for [[ ]] support
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "/bin/bash", "-c", cmd },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
