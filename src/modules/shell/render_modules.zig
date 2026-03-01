const std = @import("std");
const core = @import("core");

const LuaRuntime = core.LuaRuntime;
const segment = core.segments;
const Style = core.style.Style;
const segment_render = core.segment_render;

fn isPromptBuiltinAllowed(name: []const u8) bool {
    const allowed = [_][]const u8{
        "directory",
        "git_branch",
        "git_status",
        "status",
        "sudo",
        "jobs",
        "duration",
        "pod_name",
        "hostname",
        "username",
        "character",
    };
    for (allowed) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

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

const LuaBlock = struct {
    text: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    prefix: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize = 0,
    suffix: [32]u8 = [_]u8{0} ** 32,
    suffix_len: usize = 0,
    style: Style = .{},
};

const LuaValue = struct {
    text: [512]u8 = [_]u8{0} ** 512,
    text_len: usize = 0,
    blocks: [16]LuaBlock = [_]LuaBlock{.{}} ** 16,
    block_count: usize = 0,

    fn textSlice(self: *const LuaValue) []const u8 {
        return self.text[0..self.text_len];
    }
};

fn evalLuaCommand(runtime: *LuaRuntime, callback_runtime: ?*LuaRuntime, ctx: *segment.Context, code: []const u8) LuaValue {
    var out: LuaValue = .{};
    const rt = callback_runtime orelse runtime;
    populateLuaContext(rt, ctx);

    const code_z = rt.allocator.dupeZ(u8, code) catch return out;
    defer rt.allocator.free(code_z);

    rt.lua.loadString(code_z) catch return out;
    rt.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        rt.lua.pop(1);
        return out;
    };
    defer rt.lua.pop(1);

    switch (rt.lua.typeOf(-1)) {
        .string => {
            const s = rt.lua.toString(-1) catch return out;
            const n = @min(s.len, out.text.len);
            @memcpy(out.text[0..n], s[0..n]);
            out.text_len = n;
            return out;
        },
        .number => {
            const n = rt.lua.toNumber(-1) catch return out;
            const s = std.fmt.bufPrint(out.text[0..], "{d}", .{n}) catch "";
            out.text_len = s.len;
            return out;
        },
        .boolean => {
            if (!rt.lua.toBoolean(-1)) return out;
            @memcpy(out.text[0..4], "true");
            out.text_len = 4;
            return out;
        },
        .table => {
            const len: i32 = @intCast(@min(rt.lua.rawLen(-1), out.blocks.len));
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = rt.lua.rawGetIndex(-1, i);
                defer rt.lua.pop(1);
                if (rt.lua.typeOf(-1) != .table) continue;

                _ = rt.lua.getField(-1, "text");
                if (rt.lua.typeOf(-1) != .string) {
                    rt.lua.pop(1);
                    continue;
                }
                const txt = rt.lua.toString(-1) catch {
                    rt.lua.pop(1);
                    continue;
                };
                rt.lua.pop(1);

                if (txt.len == 0) continue;
                var blk = LuaBlock{};
                const tn = @min(txt.len, blk.text.len);
                @memcpy(blk.text[0..tn], txt[0..tn]);
                blk.len = tn;

                _ = rt.lua.getField(-1, "prefix");
                if (rt.lua.typeOf(-1) == .string) {
                    const ps = rt.lua.toString(-1) catch "";
                    const pn = @min(ps.len, blk.prefix.len);
                    @memcpy(blk.prefix[0..pn], ps[0..pn]);
                    blk.prefix_len = pn;
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "suffix");
                if (rt.lua.typeOf(-1) == .string) {
                    const ss = rt.lua.toString(-1) catch "";
                    const sn = @min(ss.len, blk.suffix.len);
                    @memcpy(blk.suffix[0..sn], ss[0..sn]);
                    blk.suffix_len = sn;
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "style");
                if (rt.lua.typeOf(-1) == .string) {
                    const ss = rt.lua.toString(-1) catch "";
                    blk.style = Style.parse(ss);
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "fg");
                if (rt.lua.typeOf(-1) == .number) {
                    const fg = rt.lua.toInteger(-1) catch -1;
                    if (fg >= 0 and fg <= 255) blk.style.fg = .{ .palette = @intCast(fg) };
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "bg");
                if (rt.lua.typeOf(-1) == .number) {
                    const bg = rt.lua.toInteger(-1) catch -1;
                    if (bg >= 0 and bg <= 255) blk.style.bg = .{ .palette = @intCast(bg) };
                }
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "bold");
                if (rt.lua.typeOf(-1) == .boolean) blk.style.bold = rt.lua.toBoolean(-1);
                rt.lua.pop(1);

                _ = rt.lua.getField(-1, "italic");
                if (rt.lua.typeOf(-1) == .boolean) blk.style.italic = rt.lua.toBoolean(-1);
                rt.lua.pop(1);

                out.blocks[out.block_count] = blk;
                out.block_count += 1;
            }
            return out;
        },
        else => return out,
    }
}

fn evalLuaGate(runtime: *LuaRuntime, ctx: *segment.Context, code: []const u8) bool {
    populateLuaContext(runtime, ctx);

    const code_z = runtime.allocator.dupeZ(u8, code) catch return false;
    defer runtime.allocator.free(code_z);

    runtime.lua.loadString(code_z) catch return false;
    runtime.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        runtime.lua.pop(1);
        return false;
    };
    defer runtime.lua.pop(1);
    return switch (runtime.lua.typeOf(-1)) {
        .boolean => runtime.lua.toBoolean(-1),
        .number => (runtime.lua.toNumber(-1) catch 0) != 0,
        .string => (runtime.lua.toString(-1) catch "").len > 0,
        else => false,
    };
}

const BuiltinDesc = struct {
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    style: Style = .{},
    prefix_buf: [32]u8 = [_]u8{0} ** 32,
    prefix_len: usize = 0,
    suffix_buf: [32]u8 = [_]u8{0} ** 32,
    suffix_len: usize = 0,

    fn name(self: *const BuiltinDesc) ?[]const u8 {
        if (self.name_len == 0) return null;
        return self.name_buf[0..self.name_len];
    }

    fn prefix(self: *const BuiltinDesc) []const u8 {
        return self.prefix_buf[0..self.prefix_len];
    }

    fn suffix(self: *const BuiltinDesc) []const u8 {
        return self.suffix_buf[0..self.suffix_len];
    }
};

fn evalLuaBuiltinDesc(runtime: *LuaRuntime, ctx: *segment.Context, code: []const u8) BuiltinDesc {
    var desc: BuiltinDesc = .{};
    populateLuaContext(runtime, ctx);

    const code_z = runtime.allocator.dupeZ(u8, code) catch return desc;
    defer runtime.allocator.free(code_z);

    runtime.lua.loadString(code_z) catch return desc;
    runtime.lua.protectedCall(.{ .args = 0, .results = 1 }) catch {
        runtime.lua.pop(1);
        return desc;
    };
    defer runtime.lua.pop(1);

    switch (runtime.lua.typeOf(-1)) {
        .string => {
            const s = runtime.lua.toString(-1) catch return desc;
            const t = std.mem.trim(u8, s, " \t\r\n");
            if (t.len > 0) {
                const n = @min(t.len, desc.name_buf.len);
                @memcpy(desc.name_buf[0..n], t[0..n]);
                desc.name_len = n;
            }
            return desc;
        },
        .table => {
            _ = runtime.lua.getField(-1, "name");
            if (runtime.lua.typeOf(-1) == .string) {
                const s = runtime.lua.toString(-1) catch "";
                const t = std.mem.trim(u8, s, " \t\r\n");
                if (t.len > 0) {
                    const n = @min(t.len, desc.name_buf.len);
                    @memcpy(desc.name_buf[0..n], t[0..n]);
                    desc.name_len = n;
                }
            }
            runtime.lua.pop(1);

            _ = runtime.lua.getField(-1, "style");
            if (runtime.lua.typeOf(-1) == .string) {
                const s = runtime.lua.toString(-1) catch "";
                desc.style = Style.parse(s);
            }
            runtime.lua.pop(1);

            _ = runtime.lua.getField(-1, "fg");
            if (runtime.lua.typeOf(-1) == .number) {
                const fg = runtime.lua.toInteger(-1) catch -1;
                if (fg >= 0 and fg <= 255) desc.style.fg = .{ .palette = @intCast(fg) };
            }
            runtime.lua.pop(1);

            _ = runtime.lua.getField(-1, "bg");
            if (runtime.lua.typeOf(-1) == .number) {
                const bg = runtime.lua.toInteger(-1) catch -1;
                if (bg >= 0 and bg <= 255) desc.style.bg = .{ .palette = @intCast(bg) };
            }
            runtime.lua.pop(1);

            _ = runtime.lua.getField(-1, "prefix");
            if (runtime.lua.typeOf(-1) == .string) {
                const s = runtime.lua.toString(-1) catch "";
                const n = @min(s.len, desc.prefix_buf.len);
                @memcpy(desc.prefix_buf[0..n], s[0..n]);
                desc.prefix_len = n;
            }
            runtime.lua.pop(1);

            _ = runtime.lua.getField(-1, "suffix");
            if (runtime.lua.typeOf(-1) == .string) {
                const s = runtime.lua.toString(-1) catch "";
                const n = @min(s.len, desc.suffix_buf.len);
                @memcpy(desc.suffix_buf[0..n], s[0..n]);
                desc.suffix_len = n;
            }
            runtime.lua.pop(1);

            return desc;
        },
        else => return desc,
    }
}

pub fn renderModulesSimple(allocator: std.mem.Allocator, callback_runtime: ?*LuaRuntime, ctx: *segment.Context, modules: []const core.Segment, stdout: std.fs.File, is_zsh: bool) !void {
    const alloc = std.heap.page_allocator;
    _ = allocator;

    const ModuleResult = struct {
        when_passed: bool = true,
        output: LuaValue = .{},
        width: u16 = 0,
        should_render: bool = true,
        visible: bool = true,
    };

    var results: [32]ModuleResult = [_]ModuleResult{.{}} ** 32;
    const mod_count = @min(modules.len, 32);

    var lua_rt: ?LuaRuntime = null;
    defer if (lua_rt) |*rt| rt.deinit();

    for (modules[0..mod_count], 0..) |mod, i| {
        if (mod.command) |cmd| {
            if (mod.kind == .progress) {
                if (mod.progress_show_when) |gate| {
                    if (lua_rt == null) lua_rt = LuaRuntime.init(alloc) catch null;
                    if (lua_rt == null) {
                        results[i].when_passed = false;
                        continue;
                    }
                    if (!evalLuaGate(&lua_rt.?, ctx, gate)) {
                        results[i].when_passed = false;
                        continue;
                    }
                }
            }
            if (lua_rt == null) lua_rt = LuaRuntime.init(alloc) catch null;
            if (lua_rt == null) {
                results[i].when_passed = false;
                continue;
            }
            if (mod.kind == .builtin) {
                const desc = evalLuaBuiltinDesc(&lua_rt.?, ctx, cmd);
                if (desc.name()) |builtin_name| {
                    var bi = LuaValue{};
                    if (isPromptBuiltinAllowed(builtin_name)) {
                        if (ctx.renderSegment(builtin_name)) |segs| {
                            const pref = desc.prefix();
                            if (pref.len > 0 and bi.block_count < bi.blocks.len) {
                                var pblk = LuaBlock{};
                                const pn = @min(pref.len, pblk.text.len);
                                @memcpy(pblk.text[0..pn], pref[0..pn]);
                                pblk.len = pn;
                                pblk.style = desc.style;
                                bi.blocks[bi.block_count] = pblk;
                                bi.block_count += 1;
                            }
                            if (segs.len > 0) {
                                for (segs) |seg_out| {
                                    if (bi.block_count >= bi.blocks.len) break;
                                    if (seg_out.text.len == 0) continue;
                                    var blk = LuaBlock{};
                                    const tn = @min(seg_out.text.len, blk.text.len);
                                    @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                                    blk.len = tn;
                                    blk.style = if (desc.style.isEmpty()) seg_out.style else desc.style;
                                    bi.blocks[bi.block_count] = blk;
                                    bi.block_count += 1;
                                }
                            }
                            const suff = desc.suffix();
                            if (suff.len > 0 and bi.block_count < bi.blocks.len) {
                                var sblk = LuaBlock{};
                                const sn = @min(suff.len, sblk.text.len);
                                @memcpy(sblk.text[0..sn], suff[0..sn]);
                                sblk.len = sn;
                                sblk.style = desc.style;
                                bi.blocks[bi.block_count] = sblk;
                                bi.block_count += 1;
                            }
                        }
                    }
                    results[i].output = bi;
                }
            } else {
                results[i].output = evalLuaCommand(&lua_rt.?, callback_runtime, ctx, cmd);
            }
        } else if (mod.builtin) |builtin_name| {
            var bi = LuaValue{};
            if (isPromptBuiltinAllowed(builtin_name)) {
                if (ctx.renderSegment(builtin_name)) |segs| {
                    if (segs.len > 0) {
                        for (segs) |seg_out| {
                            if (bi.block_count >= bi.blocks.len) break;
                            if (seg_out.text.len == 0) continue;
                            var blk = LuaBlock{};
                            const tn = @min(seg_out.text.len, blk.text.len);
                            @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                            blk.len = tn;
                            blk.style = seg_out.style;
                            bi.blocks[bi.block_count] = blk;
                            bi.block_count += 1;
                        }
                    }
                }
            }
            results[i].output = bi;
        } else if (ctx.renderSegment(mod.name)) |segs| {
            if (segs.len > 0) {
                var bi = results[i].output;
                for (segs) |seg_out| {
                    if (bi.block_count >= bi.blocks.len) break;
                    if (seg_out.text.len == 0) continue;
                    var blk = LuaBlock{};
                    const tn = @min(seg_out.text.len, blk.text.len);
                    @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                    blk.len = tn;
                    blk.style = seg_out.style;
                    bi.blocks[bi.block_count] = blk;
                    bi.block_count += 1;
                }
                results[i].output = bi;
            }
        }
    }

    for (modules[0..mod_count], 0..) |_, i| {
        if (!results[i].when_passed) {
            results[i].should_render = false;
            continue;
        }

        var output_text = results[i].output.textSlice();
        if (segment_render.builtinNameFromMarker(output_text)) |builtin_name| {
            if (isPromptBuiltinAllowed(builtin_name)) {
                if (ctx.renderSegment(builtin_name)) |segs| {
                    if (segs.len > 0) {
                        var bi = LuaValue{};
                        for (segs) |seg_out| {
                            if (bi.block_count >= bi.blocks.len) break;
                            if (seg_out.text.len == 0) continue;
                            var blk = LuaBlock{};
                            const tn = @min(seg_out.text.len, blk.text.len);
                            @memcpy(blk.text[0..tn], seg_out.text[0..tn]);
                            blk.len = tn;
                            blk.style = seg_out.style;
                            bi.blocks[bi.block_count] = blk;
                            bi.block_count += 1;
                        }
                        results[i].output = bi;
                    } else {
                        results[i].should_render = false;
                        continue;
                    }
                } else {
                    results[i].should_render = false;
                    continue;
                }
            } else {
                results[i].should_render = false;
                continue;
            }
        }

        if (results[i].output.block_count > 0) {
            for (results[i].output.blocks[0..results[i].output.block_count]) |blk| {
                const bt = blk.text[0..blk.len];
                if (segment_render.builtinNameFromMarker(bt)) |builtin_name| {
                    if (isPromptBuiltinAllowed(builtin_name)) {
                        if (ctx.renderSegment(builtin_name)) |segs| {
                            var seg_width: u16 = 0;
                            for (segs) |s| seg_width += @intCast(s.text.len);
                            if (seg_width > 0) {
                                results[i].width += seg_width;
                                results[i].width += @intCast(blk.prefix_len + blk.suffix_len);
                            }
                        }
                    }
                } else {
                    results[i].width += @intCast(blk.len);
                }
            }
        } else {
            output_text = results[i].output.textSlice();
            if (output_text.len == 0) {
                results[i].should_render = false;
                continue;
            }
            results[i].width = @intCast(output_text.len);
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
        _ = mod;
        if (!results[i].should_render or !results[i].visible) continue;

        var wrote_module = false;

        if (results[i].output.block_count > 0) {
            for (results[i].output.blocks[0..results[i].output.block_count]) |blk| {
                if (blk.len == 0) continue;
                const bt = blk.text[0..blk.len];
                const style = blk.style;
                if (segment_render.builtinNameFromMarker(bt)) |builtin_name| {
                    if (isPromptBuiltinAllowed(builtin_name)) {
                        if (ctx.renderSegment(builtin_name)) |segs| {
                            if (segs.len == 0) continue;
                            var wrote_any = false;
                            for (segs) |s| {
                                if (s.text.len > 0) {
                                    wrote_any = true;
                                    break;
                                }
                            }
                            if (!wrote_any) continue;
                            try writeStyleDirect(stdout, style, is_zsh);
                            if (blk.prefix_len > 0) try stdout.writeAll(blk.prefix[0..blk.prefix_len]);
                            for (segs) |s| {
                                try stdout.writeAll(s.text);
                                if (s.text.len > 0) wrote_module = true;
                            }
                            if (blk.suffix_len > 0) try stdout.writeAll(blk.suffix[0..blk.suffix_len]);
                            if (blk.prefix_len > 0 or blk.suffix_len > 0) wrote_module = true;
                            if (!style.isEmpty()) {
                                try writeResetDirect(stdout, is_zsh);
                            }
                        }
                    }
                } else {
                    try writeStyleDirect(stdout, style, is_zsh);
                    try stdout.writeAll(bt);
                    wrote_module = true;
                    if (!style.isEmpty()) {
                        try writeResetDirect(stdout, is_zsh);
                    }
                }
            }
        } else {
            const output_text = results[i].output.textSlice();
            const style = Style{};
            try writeStyleDirect(stdout, style, is_zsh);
            try stdout.writeAll(output_text);
            wrote_module = output_text.len > 0;
            if (!style.isEmpty()) {
                try writeResetDirect(stdout, is_zsh);
            }
        }

        if (wrote_module) {
            try writeResetDirect(stdout, is_zsh);
        }
    }
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

fn writeResetDirect(stdout: std.fs.File, is_zsh: bool) !void {
    if (is_zsh) try stdout.writeAll("%{");
    try stdout.writeAll("\x1b[0m");
    if (is_zsh) try stdout.writeAll("%}");
}
