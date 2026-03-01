const core = @import("core");
const LuaRuntime = core.LuaRuntime;

/// Emit autocmd callback(s) for `event_name`.
/// Expects payload table at stack top and always consumes it.
///
/// Supported handler shapes in Lua config:
/// - `hexe.autocmd[event_name] = function(ctx) ... end`
/// - `hexe.autocmd[event_name] = { function(ctx) ... end, ... }`
pub fn emitAutocmdWithPayloadOnStack(runtime: *LuaRuntime, event_name: []const u8) void {
    // Stack: [..., payload]
    _ = runtime.lua.getGlobal("hexe") catch {
        runtime.lua.pop(1); // payload
        return;
    };
    if (runtime.lua.typeOf(-1) != .table) {
        runtime.lua.pop(2); // hexe, payload
        return;
    }

    _ = runtime.lua.getField(-1, "autocmd");
    if (runtime.lua.typeOf(-1) != .table) {
        runtime.lua.pop(3); // autocmd/hexe/payload
        return;
    }

    _ = runtime.lua.pushString(event_name);
    _ = runtime.lua.getTable(-2);
    const handler_ty = runtime.lua.typeOf(-1);
    switch (handler_ty) {
        .function => {
            runtime.lua.pushValue(-4); // payload
            runtime.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
                runtime.lua.pop(1); // lua error object
            };
        },
        .table => {
            const len: i32 = @intCast(runtime.lua.rawLen(-1));
            var i: i32 = 1;
            while (i <= len) : (i += 1) {
                _ = runtime.lua.rawGetIndex(-1, i);
                if (runtime.lua.typeOf(-1) != .function) {
                    runtime.lua.pop(1);
                    continue;
                }
                runtime.lua.pushValue(-6); // payload
                runtime.lua.protectedCall(.{ .args = 1, .results = 0 }) catch {
                    runtime.lua.pop(1); // lua error object
                };
            }
        },
        else => {},
    }

    runtime.lua.pop(4); // handler/autocmd/hexe/payload
}
