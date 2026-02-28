const std = @import("std");
const core = @import("core");

const LuaRuntime = core.LuaRuntime;
const segment = core.segments;
const Style = core.style.Style;

fn populateLuaContext(runtime: *LuaRuntime, ctx: *segment.Context) void {
    runtime.lua.createTable(0, 8);
    _ = runtime.lua.pushString(ctx.cwd);
    runtime.lua.setField(-2, "cwd");

    if (ctx.home) |home| {
        _ = runtime.lua.pushString(home);
        runtime.lua.setField(-2, "home");
    }

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
    runtime.lua.pushInteger(@intCast(ctx.now_ms));
    runtime.lua.setField(-2, "now_ms");

    var env_map = std.process.getEnvMap(runtime.allocator) catch {
        runtime.lua.createTable(0, 0);
        runtime.lua.setField(-2, "env");
        runtime.lua.setGlobal("ctx");
        return;
    };
    defer env_map.deinit();

    runtime.lua.createTable(0, @intCast(env_map.count()));
    var it = env_map.iterator();
    while (it.next()) |entry| {
        _ = runtime.lua.pushString(entry.key_ptr.*);
        _ = runtime.lua.pushString(entry.value_ptr.*);
        runtime.lua.setTable(-3);
    }
    runtime.lua.setField(-2, "env");

    runtime.lua.setGlobal("ctx");
}

fn evalLuaWhen(runtime: *LuaRuntime, ctx: *segment.Context, code: []const u8) bool {
    populateLuaContext(runtime, ctx);

    const code_z = runtime.allocator.dupeZ(u8, code) catch return false;
    defer runtime.allocator.free(code_z);

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

fn evalLuaCommand(runtime: *LuaRuntime, ctx: *segment.Context, code: []const u8) ?[]const u8 {
    populateLuaContext(runtime, ctx);

    const code_z = runtime.allocator.dupeZ(u8, code) catch return null;
    defer runtime.allocator.free(code_z);

    runtime.lua.loadString(code_z) catch return null;
    runtime.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        runtime.lua.pop(1);
        return null;
    };
    defer runtime.lua.pop(1);

    switch (runtime.lua.typeOf(-1)) {
        .string => {
            const s = runtime.lua.toString(-1) catch return null;
            if (s.len == 0) return null;
            return runtime.allocator.dupe(u8, s) catch null;
        },
        .number => {
            const n = runtime.lua.toNumber(-1) catch return null;
            return std.fmt.allocPrint(runtime.allocator, "{d}", .{n}) catch null;
        },
        .boolean => {
            if (!runtime.lua.toBoolean(-1)) return null;
            return runtime.allocator.dupe(u8, "true") catch null;
        },
        else => return null,
    }
}

fn luaCommandCode(command: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, command, "lua:")) return null;
    const body = std.mem.trim(u8, command[4..], " \t\r\n");
    if (body.len == 0) return null;
    return body;
}

pub fn renderModulesSimple(allocator: std.mem.Allocator, ctx: *segment.Context, modules: []const core.Segment, stdout: std.fs.File, is_zsh: bool) !void {
    const alloc = std.heap.page_allocator;
    _ = allocator;

    const conditional_segments = [_][]const u8{ "status", "sudo", "git_branch", "git_status", "jobs", "duration", "pod_name" };

    const ModuleResult = struct {
        when_passed: bool = true,
        needs_bash_check: bool = false,
        output: ?[]const u8 = null,
        width: u16 = 0,
        should_render: bool = true,
        visible: bool = true,
    };

    var results: [32]ModuleResult = [_]ModuleResult{.{}} ** 32;
    const mod_count = @min(modules.len, 32);

    var lua_rt: ?LuaRuntime = null;
    defer if (lua_rt) |*rt| rt.deinit();

    for (modules[0..mod_count], 0..) |mod, i| {
        if (mod.when) |w| {
            if (w.env) |env_name| {
                const val = std.posix.getenv(env_name);
                if (val == null or val.?.len == 0) {
                    results[i].when_passed = false;
                    continue;
                }
            }
            if (w.env_not) |env_name| {
                const val = std.posix.getenv(env_name);
                if (val != null and val.?.len > 0) {
                    results[i].when_passed = false;
                    continue;
                }
            }

            if (w.lua) |lua_code| {
                if (lua_rt == null) lua_rt = LuaRuntime.init(alloc) catch null;
                if (lua_rt == null or !evalLuaWhen(&lua_rt.?, ctx, lua_code)) {
                    results[i].when_passed = false;
                    continue;
                }
            }

            if (w.bash != null) results[i].needs_bash_check = true;
        }

        if (mod.command) |cmd| {
            if (luaCommandCode(cmd)) |lua_code| {
                if (lua_rt == null) lua_rt = LuaRuntime.init(alloc) catch null;
                if (lua_rt == null) {
                    results[i].when_passed = false;
                    continue;
                }
                results[i].output = evalLuaCommand(&lua_rt.?, ctx, lua_code);
            }
        }
    }

    const ThreadContext = struct {
        mod: *const core.Segment,
        result: *ModuleResult,
        alloc: std.mem.Allocator,
    };

    const thread_fn = struct {
        fn run(tctx: ThreadContext) void {
            if (tctx.result.needs_bash_check) {
                if (tctx.mod.when) |w| {
                    if (w.bash) |bash_code| {
                        const res = std.process.Child.run(.{
                            .allocator = tctx.alloc,
                            .argv = &.{ "/bin/bash", "-c", bash_code },
                        }) catch {
                            tctx.result.when_passed = false;
                            return;
                        };
                        tctx.alloc.free(res.stdout);
                        tctx.alloc.free(res.stderr);
                        const ok = switch (res.term) {
                            .Exited => |code| code == 0,
                            else => false,
                        };
                        if (!ok) {
                            tctx.result.when_passed = false;
                            return;
                        }
                    }
                }
            }

            if (!tctx.result.when_passed) return;

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

    var threads: [32]?std.Thread = [_]?std.Thread{null} ** 32;
    for (modules[0..mod_count], 0..) |*mod, i| {
        const has_bash_command = if (mod.command) |cmd| luaCommandCode(cmd) == null else false;
        if (results[i].needs_bash_check or (has_bash_command and results[i].when_passed)) {
            threads[i] = std.Thread.spawn(.{}, thread_fn, .{ThreadContext{
                .mod = mod,
                .result = &results[i],
                .alloc = alloc,
            }}) catch null;
        }
    }

    for (threads[0..mod_count]) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }

    for (modules[0..mod_count], 0..) |mod, i| {
        if (!results[i].when_passed) {
            results[i].should_render = false;
            continue;
        }

        var output_text: []const u8 = "";

        if (mod.command != null) {
            if (results[i].output) |out| {
                output_text = std.mem.trimRight(u8, out, "\n\r");
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
                if (segs.len > 0) output_text = segs[0].text;
            } else if (is_conditional) {
                results[i].should_render = false;
                continue;
            }
        }

        results[i].output = output_text;
        for (mod.outputs) |out| {
            results[i].width += calcFormatWidth(out.format, output_text);
        }
    }

    const width_budget = ctx.terminal_width / 2;
    var used_width: u16 = 0;

    var priority_order: [32]usize = undefined;
    for (0..mod_count) |i| priority_order[i] = i;

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

    for (priority_order[0..mod_count]) |idx| {
        if (!results[idx].should_render) continue;
        if (used_width + results[idx].width <= width_budget) {
            results[idx].visible = true;
            used_width += results[idx].width;
        } else {
            results[idx].visible = false;
        }
    }

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
