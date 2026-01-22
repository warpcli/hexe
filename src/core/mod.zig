// Core - built entirely on ghostty-vt

pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const config = @import("config.zig");
pub const ipc = @import("ipc.zig");
pub const pod_protocol = @import("pod_protocol.zig");
pub const lua_runtime = @import("lua_runtime.zig");

pub const LuaRuntime = lua_runtime.LuaRuntime;
pub const ConfigStatus = lua_runtime.ConfigStatus;

pub const Pty = pty.Pty;
pub const VT = vt.VT;

// IPC exports
pub const IpcServer = ipc.Server;
pub const IpcClient = ipc.Client;
pub const IpcConnection = ipc.Connection;
pub const Config = config.Config;
pub const FloatDef = config.FloatDef;
pub const FloatStyle = config.FloatStyle;
pub const FloatStylePosition = config.FloatStylePosition;
pub const BorderColor = config.BorderColor;
pub const SplitStyle = config.SplitStyle;
pub const SplitsConfig = config.SplitsConfig;
pub const PanesConfig = config.PanesConfig;
pub const StatusModule = config.StatusModule;
pub const OutputDef = config.OutputDef;
pub const NotificationStyleConfig = config.NotificationStyleConfig;
pub const NotificationConfig = config.NotificationConfig;
