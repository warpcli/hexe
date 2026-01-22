const std = @import("std");
const argonaut = @import("argonaut");
const core = @import("core");
const ipc = core.ipc;
const mux = @import("mux");
const ses = @import("ses");
const pod = @import("pod");
const shp = @import("shp");
const com = @import("commands/com.zig");

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Create main parser
    const parser = try argonaut.newParser(allocator, "hexe", "Hexe terminal multiplexer");
    defer parser.deinit();

    // Top-level subcommands only
    const com_cmd = try parser.newCommand("com", "Communication with sessions and panes");
    const ses_cmd = try parser.newCommand("ses", "Session daemon management");
    const pod_cmd = try parser.newCommand("pod", "Per-pane PTY daemon (internal)");
    const mux_cmd = try parser.newCommand("mux", "Terminal multiplexer");
    const shp_cmd = try parser.newCommand("shp", "Shell prompt renderer");
    const pop_cmd = try parser.newCommand("pop", "Popup overlays");

    // COM subcommands
    const com_list = try com_cmd.newCommand("list", "List all sessions and panes");
    const com_list_details = try com_list.flag("d", "details", null);

    const com_info = try com_cmd.newCommand("info", "Show current pane info");
    const com_info_uuid = try com_info.string("u", "uuid", null);
    const com_info_creator = try com_info.flag("c", "creator", null);
    const com_info_last = try com_info.flag("l", "last", null);

    const com_notify = try com_cmd.newCommand("notify", "Send notification");
    const com_notify_uuid = try com_notify.string("u", "uuid", null);
    const com_notify_creator = try com_notify.flag("c", "creator", null);
    const com_notify_last = try com_notify.flag("l", "last", null);
    const com_notify_broadcast = try com_notify.flag("b", "broadcast", null);
    const com_notify_msg = try com_notify.stringPositional(null);

    const com_send = try com_cmd.newCommand("send", "Send keystrokes to pane");
    const com_send_uuid = try com_send.string("u", "uuid", null);
    const com_send_creator = try com_send.flag("c", "creator", null);
    const com_send_last = try com_send.flag("l", "last", null);
    const com_send_broadcast = try com_send.flag("b", "broadcast", null);
    const com_send_enter = try com_send.flag("e", "enter", null);
    const com_send_ctrl = try com_send.string("C", "ctrl", null);
    const com_send_text = try com_send.stringPositional(null);

    const com_exit_intent = try com_cmd.newCommand("exit-intent", "Ask mux permission before shell exits");

    const com_shell_event = try com_cmd.newCommand("shell-event", "Send shell command metadata to mux/ses");
    const com_shell_event_cmd = try com_shell_event.string("", "cmd", null);
    const com_shell_event_status = try com_shell_event.int("", "status", null);
    const com_shell_event_duration = try com_shell_event.int("", "duration", null);
    const com_shell_event_cwd = try com_shell_event.string("", "cwd", null);
    const com_shell_event_jobs = try com_shell_event.int("", "jobs", null);

    // SES subcommands
    const ses_daemon = try ses_cmd.newCommand("daemon", "Start the session daemon");
    const ses_daemon_fg = try ses_daemon.flag("f", "foreground", null);
    const ses_daemon_dbg = try ses_daemon.flag("d", "debug", null);
    const ses_daemon_log = try ses_daemon.string("L", "logfile", null);
    _ = try ses_cmd.newCommand("info", "Show daemon info");

    // POD subcommands (mostly for ses-internal use)
    const pod_daemon = try pod_cmd.newCommand("daemon", "Start a per-pane pod daemon");
    const pod_daemon_uuid = try pod_daemon.string("u", "uuid", null);
    const pod_daemon_name = try pod_daemon.string("n", "name", null);
    const pod_daemon_socket = try pod_daemon.string("s", "socket", null);
    const pod_daemon_shell = try pod_daemon.string("S", "shell", null);
    const pod_daemon_cwd = try pod_daemon.string("C", "cwd", null);
    const pod_daemon_fg = try pod_daemon.flag("f", "foreground", null);
    const pod_daemon_dbg = try pod_daemon.flag("d", "debug", null);
    const pod_daemon_log = try pod_daemon.string("L", "logfile", null);

    // MUX subcommands
    const mux_new = try mux_cmd.newCommand("new", "Create new multiplexer session");
    const mux_new_name = try mux_new.string("n", "name", null);
    const mux_new_dbg = try mux_new.flag("d", "debug", null);
    const mux_new_log = try mux_new.string("L", "logfile", null);

    const mux_attach = try mux_cmd.newCommand("attach", "Attach to existing session");
    const mux_attach_name = try mux_attach.stringPositional(null);
    const mux_attach_dbg = try mux_attach.flag("d", "debug", null);
    const mux_attach_log = try mux_attach.string("L", "logfile", null);

    const mux_float = try mux_cmd.newCommand("float", "Spawn a transient float pane");
    const mux_float_uuid = try mux_float.string("u", "uuid", null);
    const mux_float_command = try mux_float.string("c", "command", null);
    const mux_float_title = try mux_float.string("", "title", null);
    const mux_float_cwd = try mux_float.string("", "cwd", null);
    const mux_float_result_file = try mux_float.string("", "result-file", null);
    const mux_float_pass_env = try mux_float.flag("", "pass-env", null);
    const mux_float_extra_env = try mux_float.string("", "extra-env", null);
    const mux_float_isolated = try mux_float.flag("", "isolated", null);

    // POP subcommands
    const shp_prompt = try shp_cmd.newCommand("prompt", "Render shell prompt");
    const shp_prompt_status = try shp_prompt.int("s", "status", null);
    const shp_prompt_duration = try shp_prompt.int("d", "duration", null);
    const shp_prompt_right = try shp_prompt.flag("r", "right", null);
    const shp_prompt_shell = try shp_prompt.string("S", "shell", null);
    const shp_prompt_jobs = try shp_prompt.int("j", "jobs", null);

    const shp_init = try shp_cmd.newCommand("init", "Print shell initialization script");
    const shp_init_shell = try shp_init.stringPositional(null);
    const shp_init_no_comms = try shp_init.flag("", "no-comms", null);

    // POP subcommands
    const pop_notify = try pop_cmd.newCommand("notify", "Show notification");
    const pop_notify_uuid = try pop_notify.string("u", "uuid", null);
    const pop_notify_timeout = try pop_notify.int("t", "timeout", null);
    const pop_notify_msg = try pop_notify.stringPositional(null);

    const pop_confirm = try pop_cmd.newCommand("confirm", "Yes/No dialog");
    const pop_confirm_uuid = try pop_confirm.string("u", "uuid", null);
    const pop_confirm_timeout = try pop_confirm.int("t", "timeout", null);
    const pop_confirm_msg = try pop_confirm.stringPositional(null);

    const pop_choose = try pop_cmd.newCommand("choose", "Select from options");
    const pop_choose_uuid = try pop_choose.string("u", "uuid", null);
    const pop_choose_timeout = try pop_choose.int("t", "timeout", null);
    const pop_choose_items = try pop_choose.string("i", "items", null);
    const pop_choose_msg = try pop_choose.stringPositional(null);

    // Check for help flag manually to avoid argonaut segfault
    var has_help = false;
    var found_com = false;
    var found_ses = false;
    var found_pod = false;
    var found_mux = false;
    var found_shp = false;
    var found_list = false;
    var found_notify = false;
    var found_daemon = false;
    var found_info = false;
    var found_new = false;
    var found_attach = false;
    var found_float = false;
    var found_prompt = false;
    var found_init = false;
    var found_pop = false;
    var found_confirm = false;
    var found_choose = false;
    var found_send = false;
    var found_exit_intent = false;
    var found_shell_event = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) has_help = true;
        if (std.mem.eql(u8, arg, "com")) found_com = true;
        if (std.mem.eql(u8, arg, "ses")) found_ses = true;
        if (std.mem.eql(u8, arg, "pod")) found_pod = true;
        if (std.mem.eql(u8, arg, "mux")) found_mux = true;
        if (std.mem.eql(u8, arg, "shp")) found_shp = true;
        if (std.mem.eql(u8, arg, "list")) found_list = true;
        if (std.mem.eql(u8, arg, "info")) found_info = true;
        if (std.mem.eql(u8, arg, "notify")) found_notify = true;
        if (std.mem.eql(u8, arg, "daemon")) found_daemon = true;
        if (std.mem.eql(u8, arg, "info")) found_info = true;
        if (std.mem.eql(u8, arg, "new")) found_new = true;
        if (std.mem.eql(u8, arg, "attach")) found_attach = true;
        if (std.mem.eql(u8, arg, "float")) found_float = true;
        if (std.mem.eql(u8, arg, "prompt")) found_prompt = true;
        if (std.mem.eql(u8, arg, "init")) found_init = true;
        if (std.mem.eql(u8, arg, "pop")) found_pop = true;
        if (std.mem.eql(u8, arg, "confirm")) found_confirm = true;
        if (std.mem.eql(u8, arg, "choose")) found_choose = true;
        if (std.mem.eql(u8, arg, "send")) found_send = true;
        if (std.mem.eql(u8, arg, "exit-intent")) found_exit_intent = true;
        if (std.mem.eql(u8, arg, "shell-event")) found_shell_event = true;
    }

    if (has_help) {
        // Show help for the most specific command found (manual strings to avoid argonaut crash)
        if (found_com and found_send) {
            print("Usage: hexe com send [OPTIONS] [text]\n\nSend keystrokes to pane (defaults to current pane if inside mux)\n\nOptions:\n  -u, --uuid <UUID>  Target specific pane\n  -c, --creator      Send to pane that created current pane\n  -l, --last         Send to previously focused pane\n  -b, --broadcast    Broadcast to all attached panes\n  -e, --enter        Append Enter key after text\n  -C, --ctrl <char>  Send Ctrl+<char> (e.g., -C c for Ctrl+C)\n", .{});
        } else if (found_com and found_exit_intent) {
            print("Usage: hexe com exit-intent\n\nAsk the current mux session whether the shell should be allowed to exit.\nIntended for shell keybindings (exit/Ctrl+D) to avoid last-pane death.\n\nExit codes: 0=allow, 1=deny\n", .{});
        } else if (found_com and found_shell_event) {
            print("Usage: hexe com shell-event [--cmd <TEXT>] [--status <N>] [--duration <MS>] [--cwd <PATH>] [--jobs <N>]\n\nSend shell command metadata to the current mux session.\nUsed by shell integration to power statusbar + `hexe com info`.\n\nNotes:\n  - No-op outside a mux session\n  - If mux is unreachable, exits 0\n", .{});
        } else if (found_com and found_notify) {
            print("Usage: hexe com notify [OPTIONS] <message>\n\nSend notification (defaults to current pane if inside mux)\n\nOptions:\n  -u, --uuid <UUID>  Target specific mux or pane\n  -c, --creator      Send to pane that created current pane\n  -l, --last         Send to previously focused pane\n  -b, --broadcast    Broadcast to all muxes\n", .{});
        } else if (found_com and found_info) {
            print("Usage: hexe com info [OPTIONS]\n\nShow information about a pane\n\nOptions:\n  -u, --uuid <UUID>  Query specific pane by UUID (works from anywhere)\n  -c, --creator      Print only the creator pane UUID\n  -l, --last         Print only the last focused pane UUID\n\nWithout --uuid, queries current pane (requires running inside mux)\n", .{});
        } else if (found_com and found_list) {
            print("Usage: hexe com list [OPTIONS]\n\nList all sessions and panes\n\nOptions:\n  -d, --details  Show extra details\n", .{});
        } else if (found_ses and found_daemon) {
            print("Usage: hexe ses daemon [OPTIONS]\n\nStart the session daemon\n\nOptions:\n  -f, --foreground     Run in foreground (don't daemonize)\n  -d, --debug          Enable debug output\n  -L, --logfile <PATH> Log debug output to PATH\n", .{});
        } else if (found_ses and found_info) {
            print("Usage: hexe ses info\n\nShow daemon status and socket path\n", .{});
        } else if (found_pod and found_daemon) {
            print("Usage: hexe pod daemon [OPTIONS]\n\nStart a per-pane pod daemon (normally launched by ses)\n\nOptions:\n  -u, --uuid <UUID>     Pane UUID (32 hex chars)\n  -n, --name <NAME>     Human-friendly pane name (for `ps`)\n  -s, --socket <PATH>   Pod unix socket path\n  -S, --shell <CMD>     Shell/command to run\n  -C, --cwd <DIR>       Working directory\n  -f, --foreground      Run in foreground (prints pod_ready JSON)\n  -d, --debug           Enable debug output\n  -L, --logfile <PATH>  Log debug output to PATH\n", .{});
        } else if (found_mux and found_new) {
            print("Usage: hexe mux new [OPTIONS]\n\nCreate new multiplexer session\n\nOptions:\n  -n, --name <NAME>     Session name\n  -d, --debug           Enable debug output\n  -L, --logfile <PATH>  Log debug output to PATH\n", .{});
        } else if (found_mux and found_attach) {
            print("Usage: hexe mux attach [OPTIONS] <name>\n\nAttach to existing session by name or UUID prefix\n\nOptions:\n  -d, --debug           Enable debug output\n  -L, --logfile <PATH>  Log debug output to PATH\n", .{});
        } else if (found_mux and found_float) {
            print("Usage: hexe mux float [OPTIONS]\n\nSpawn a transient float pane (blocking)\n\nOptions:\n  -u, --uuid <UUID>            Target mux UUID (optional if inside mux)\n  -c, --command <COMMAND>      Command to run in the float\n      --title <TEXT>           Border title for the float\n      --cwd <PATH>             Working directory for the float\n      --result-file <PATH>     Read selection from PATH after exit\n      --pass-env               Send current environment to the pod\n      --extra-env <KEY=VAL,..>  Extra environment variables (comma-separated)\n      --isolated               Run command with filesystem/cgroup isolation\n", .{});
        } else if (found_shp and found_prompt) {
            print("Usage: hexe shp prompt [OPTIONS]\n\nRender shell prompt\n\nOptions:\n  -s, --status <N>    Exit status of last command\n  -d, --duration <N>  Duration of last command in ms\n  -r, --right         Render right prompt\n  -S, --shell <SHELL> Shell type (bash, zsh, fish)\n  -j, --jobs <N>      Number of background jobs\n", .{});
        } else if (found_shp and found_init) {
            print("Usage: hexe shp init <shell> [--no-comms]\n\nPrint shell initialization script\n\nSupported shells: bash, zsh, fish\n\nOptions:\n      --no-comms  Disable shell->mux communication hooks\n", .{});
        } else if (found_pop and found_notify) {
            print("Usage: hexe pop notify [OPTIONS] <message>\n\nShow notification\n\nOptions:\n  -u, --uuid <UUID>     Target mux/tab/pane UUID\n  -t, --timeout <MS>    Duration in milliseconds (default: 3000)\n", .{});
        } else if (found_pop and found_confirm) {
            print("Usage: hexe pop confirm [OPTIONS] <message>\n\nYes/No dialog (blocking)\n\nOptions:\n  -u, --uuid <UUID>     Target mux/tab/pane UUID\n  -t, --timeout <MS>    Auto-cancel after milliseconds (returns false)\n\nExit codes: 0=confirmed, 1=cancelled/timeout\n", .{});
        } else if (found_pop and found_choose) {
            print("Usage: hexe pop choose [OPTIONS] <message>\n\nSelect from options (blocking)\n\nOptions:\n  -u, --uuid <UUID>      Target mux/tab/pane UUID\n  -t, --timeout <MS>     Auto-cancel after milliseconds\n  -i, --items <ITEMS>    Comma-separated list of options\n\nExit codes: 0=selected (index on stdout), 1=cancelled/timeout\n", .{});
        } else if (found_pop) {
            print("Usage: hexe pop <command>\n\nPopup overlays\n\nCommands:\n  notify   Show notification\n  confirm  Yes/No dialog\n  choose   Select from options\n", .{});
        } else if (found_com) {
            print("Usage: hexe com <command>\n\nCommunication with sessions and panes\n\nCommands:\n  list         List all sessions and panes\n  info         Show current pane info\n  notify       Send notification\n  send         Send keystrokes to pane\n  exit-intent  Ask mux permission before shell exits\n  shell-event  Send shell metadata to mux\n", .{});
        } else if (found_ses) {
            print("Usage: hexe ses <command>\n\nSession daemon management\n\nCommands:\n  daemon  Start the session daemon\n  info    Show daemon info\n", .{});
        } else if (found_pod) {
            print("Usage: hexe pod <command>\n\nPer-pane PTY daemon (internal)\n\nCommands:\n  daemon  Start a per-pane pod daemon\n", .{});
        } else if (found_mux) {
            print("Usage: hexe mux <command>\n\nTerminal multiplexer\n\nCommands:\n  new     Create new multiplexer session\n  attach  Attach to existing session\n  float   Spawn a transient float pane\n", .{});
        } else if (found_shp) {
            print("Usage: hexe shp <command>\n\nShell prompt renderer\n\nCommands:\n  prompt  Render shell prompt\n  init    Print shell initialization script\n", .{});
        } else {
            print("Usage: hexe <command>\n\nHexe terminal multiplexer\n\nCommands:\n  com  Communication with sessions and panes\n  ses  Session daemon management\n  pod  Per-pane PTY daemon (internal)\n  mux  Terminal multiplexer\n  shp  Shell prompt renderer\n  pop  Popup overlays\n", .{});
        }
        return;
    }

    // Parse
    parser.parse(args) catch |err| {
        if (err == error.HelpRequested) return;
        if (err == error.SubCommandRequired) {
            // Show help for the deepest command that happened
            if (pop_cmd.happened) {
                const help = try pop_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (shp_cmd.happened) {
                const help = try shp_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (mux_cmd.happened) {
                const help = try mux_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (ses_cmd.happened) {
                const help = try ses_cmd.usage(null);
                print("{s}\n", .{help});
            } else if (com_cmd.happened) {
                const help = try com_cmd.usage(null);
                print("{s}\n", .{help});
            } else {
                const help = try parser.usage(null);
                print("{s}\n", .{help});
            }
            return;
        }
        return err;
    };

    // Route to handlers
    if (com_cmd.happened) {
        if (com_list.happened) {
            try com.runList(allocator, com_list_details.*);
        } else if (com_info.happened) {
            try com.runInfo(allocator, com_info_uuid.*, com_info_creator.*, com_info_last.*);
        } else if (com_notify.happened) {
            try com.runNotify(allocator, com_notify_uuid.*, com_notify_creator.*, com_notify_last.*, com_notify_broadcast.*, com_notify_msg.*);
        } else if (com_send.happened) {
            try com.runSend(allocator, com_send_uuid.*, com_send_creator.*, com_send_last.*, com_send_broadcast.*, com_send_enter.*, com_send_ctrl.*, com_send_text.*);
        } else if (com_exit_intent.happened) {
            try com.runExitIntent(allocator);
        } else if (com_shell_event.happened) {
            try com.runShellEvent(allocator, com_shell_event_cmd.*, com_shell_event_status.*, com_shell_event_duration.*, com_shell_event_cwd.*, com_shell_event_jobs.*);
        }
    } else if (ses_cmd.happened) {
        // Check which ses subcommand
        for (ses_cmd.commands.items) |cmd| {
            if (cmd.happened) {
                if (std.mem.eql(u8, cmd.name, "daemon")) {
                    try runSesDaemon(ses_daemon_fg.*, ses_daemon_dbg.*, ses_daemon_log.*);
                } else if (std.mem.eql(u8, cmd.name, "info")) {
                    try runSesInfo(allocator);
                }
                return;
            }
        }
    } else if (pod_cmd.happened) {
        if (pod_daemon.happened) {
            try runPodDaemon(
                pod_daemon_fg.*,
                pod_daemon_uuid.*,
                pod_daemon_name.*,
                pod_daemon_socket.*,
                pod_daemon_shell.*,
                pod_daemon_cwd.*,
                pod_daemon_dbg.*,
                pod_daemon_log.*,
            );
        }
        return;
    } else if (mux_cmd.happened) {
        if (mux_new.happened) {
            try runMuxNew(mux_new_name.*, mux_new_dbg.*, mux_new_log.*);
        } else if (mux_attach.happened) {
            try runMuxAttach(mux_attach_name.*, mux_attach_dbg.*, mux_attach_log.*);
        } else if (mux_float.happened) {
            try runMuxFloat(
                allocator,
                mux_float_uuid.*,
                mux_float_command.*,
                mux_float_title.*,
                mux_float_cwd.*,
                mux_float_result_file.*,
                mux_float_pass_env.*,
                mux_float_extra_env.*,
                mux_float_isolated.*,
            );
        }
    } else if (shp_cmd.happened) {
        if (shp_prompt.happened) {
            try runShpPrompt(shp_prompt_status.*, shp_prompt_duration.*, shp_prompt_right.*, shp_prompt_shell.*, shp_prompt_jobs.*);
        } else if (shp_init.happened) {
            try runShpInit(shp_init_shell.*, shp_init_no_comms.*);
        }
    } else if (pop_cmd.happened) {
        if (pop_notify.happened) {
            try runPopNotify(allocator, pop_notify_uuid.*, pop_notify_timeout.*, pop_notify_msg.*);
        } else if (pop_confirm.happened) {
            try runPopConfirm(allocator, pop_confirm_uuid.*, pop_confirm_timeout.*, pop_confirm_msg.*);
        } else if (pop_choose.happened) {
            try runPopChoose(allocator, pop_choose_uuid.*, pop_choose_timeout.*, pop_choose_items.*, pop_choose_msg.*);
        }
    }
}

// ============================================================================
// SES handlers
// ============================================================================

fn runSesDaemon(foreground: bool, debug: bool, log_file: []const u8) !void {
    // Call ses run() - daemon mode unless foreground flag is set
    try ses.run(.{ .daemon = !foreground, .debug = debug, .log_file = if (log_file.len > 0) log_file else null });
}

fn runSesInfo(allocator: std.mem.Allocator) !void {
    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    print("ses daemon running at: {s}\n", .{socket_path});
}

// ============================================================================
// POD handlers
// ============================================================================

fn runPodDaemon(foreground: bool, uuid: []const u8, name: []const u8, socket_path: []const u8, shell: []const u8, cwd: []const u8, debug: bool, log_file: []const u8) !void {
    if (uuid.len == 0 or socket_path.len == 0) {
        print("Error: --uuid and --socket required\n", .{});
        return;
    }

    try pod.run(.{
        .daemon = !foreground,
        .uuid = uuid,
        .name = if (name.len > 0) name else null,
        .socket_path = socket_path,
        .shell = if (shell.len > 0) shell else null,
        .cwd = if (cwd.len > 0) cwd else null,
        .debug = debug,
        .log_file = if (log_file.len > 0) log_file else null,
        .emit_ready = foreground,
    });
}

// ============================================================================
// MUX handlers
// ============================================================================

fn runMuxNew(name: []const u8, debug: bool, log_file: []const u8) !void {
    // Call mux run() directly
    try mux.run(.{
        .name = if (name.len > 0) name else null,
        .debug = debug,
        .log_file = if (log_file.len > 0) log_file else null,
    });
}

fn runMuxAttach(name: []const u8, debug: bool, log_file: []const u8) !void {
    if (name.len > 0) {
        // Call mux run() directly with attach option
        try mux.run(.{
            .attach = name,
            .debug = debug,
            .log_file = if (log_file.len > 0) log_file else null,
        });
    } else {
        print("Error: session name required\n", .{});
    }
}

fn runMuxFloat(
    allocator: std.mem.Allocator,
    mux_uuid: []const u8,
    command: []const u8,
    title: []const u8,
    cwd: []const u8,
    result_file: []const u8,
    pass_env: bool,
    extra_env: []const u8,
    isolated: bool,
) !void {
    if (command.len == 0) {
        print("Error: --command is required\n", .{});
        return;
    }

    var socket_path_buf: ?[]const u8 = null;
    if (mux_uuid.len > 0) {
        socket_path_buf = try ipc.getMuxSocketPath(allocator, mux_uuid);
    } else {
        socket_path_buf = std.posix.getenv("HEXE_MUX_SOCKET");
    }

    const socket_path = socket_path_buf orelse {
        print("Error: --uuid required (or run inside hexe mux)\n", .{});
        return;
    };
    defer if (mux_uuid.len > 0) allocator.free(socket_path);

    var env_json: std.ArrayList(u8) = .empty;
    defer env_json.deinit(allocator);
    var env_file_path: ?[]u8 = null;
    defer if (env_file_path) |path| allocator.free(path);
    if (pass_env) {
        const tmp_uuid = core.ipc.generateUuid();
        env_file_path = std.fmt.allocPrint(allocator, "/tmp/hexe-float-env-{s}.env", .{tmp_uuid}) catch null;
        if (env_file_path) |path| {
            const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
            if (file) |env_file| {
                defer env_file.close();
                var env_map = std.process.getEnvMap(allocator) catch std.process.EnvMap.init(allocator);
                defer env_map.deinit();
                var it = env_map.iterator();
                while (it.next()) |entry| {
                    env_file.writeAll(entry.key_ptr.*) catch {};
                    env_file.writeAll("=") catch {};
                    env_file.writeAll(entry.value_ptr.*) catch {};
                    env_file.writeAll("\n") catch {};
                }
            }
        }
    }

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("mux is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var extra_env_json: std.ArrayList(u8) = .empty;
    defer extra_env_json.deinit(allocator);
    if (extra_env.len > 0) {
        try extra_env_json.appendSlice(allocator, "[");
        var it = std.mem.splitScalar(u8, extra_env, ',');
        var first = true;
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " ");
            if (trimmed.len == 0) continue;
            if (!first) try extra_env_json.appendSlice(allocator, ",");
            try extra_env_json.appendSlice(allocator, "\"");
            try appendJsonEscaped(&extra_env_json, allocator, trimmed);
            try extra_env_json.appendSlice(allocator, "\"");
            first = false;
        }
        try extra_env_json.appendSlice(allocator, "]");
    }

    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(allocator);
    var writer = msg_buf.writer(allocator);
    try writer.writeAll("{\"type\":\"float\",\"wait\":true");
    try writer.writeAll(",\"command\":\"");
    try writeJsonEscaped(writer, command);
    try writer.writeAll("\"");
    if (title.len > 0) {
        try writer.writeAll(",\"title\":\"");
        try writeJsonEscaped(writer, title);
        try writer.writeAll("\"");
    }
    if (cwd.len > 0) {
        try writer.writeAll(",\"cwd\":\"");
        try writeJsonEscaped(writer, cwd);
        try writer.writeAll("\"");
    }
    if (result_file.len > 0) {
        try writer.writeAll(",\"result_file\":\"");
        try writeJsonEscaped(writer, result_file);
        try writer.writeAll("\"");
    }
    if (env_file_path) |path| {
        try writer.writeAll(",\"env_file\":\"");
        try writeJsonEscaped(writer, path);
        try writer.writeAll("\"");
    }
    if (env_json.items.len > 0) {
        try writer.print(",\"env\":{s}", .{env_json.items});
    }
    if (extra_env_json.items.len > 0) {
        try writer.print(",\"extra_env\":{s}", .{extra_env_json.items});
    }
    if (isolated) {
        try writer.writeAll(",\"isolated\":true");
    }
    try writer.writeAll("}");

    var conn = client.toConnection();
    conn.sendLine(msg_buf.items) catch |err| {
        print("Error: {s}\n", .{@errorName(err)});
        return;
    };

    var resp_buf: [65536]u8 = undefined;
    const response = conn.recvLine(&resp_buf) catch null;
    if (response == null) {
        print("No response from mux\n", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.?, .{}) catch {
        print("Invalid response from mux\n", .{});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("type")) |t| {
        if (std.mem.eql(u8, t.string, "float_result")) {
            const stdout_content = if (root.get("stdout")) |v| v.string else "";
            if (stdout_content.len > 0) {
                _ = std.posix.write(std.posix.STDOUT_FILENO, stdout_content) catch {};
                _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
            }
            const exit_code: u8 = if (root.get("exit_code")) |v| @intCast(@max(@as(i64, 0), v.integer)) else 0;
            std.process.exit(exit_code);
        }
        if (std.mem.eql(u8, t.string, "error")) {
            if (root.get("message")) |m| {
                print("Error: {s}\n", .{m.string});
            }
            return;
        }
    }

    print("Unexpected response from mux\n", .{});
}

fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try list.append(allocator, ' ');
                } else {
                    try list.append(allocator, ch);
                }
            },
        }
    }
}

fn writeJsonEscaped(writer: anytype, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.writeByte(' ');
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

// ============================================================================
// SHP handlers
// ============================================================================

fn runShpPrompt(status: i64, duration: i64, right: bool, shell: []const u8, jobs: i64) !void {
    try shp.run(.{
        .prompt = true,
        .status = status,
        .duration = duration,
        .right = right,
        .shell = if (shell.len > 0) shell else null,
        .jobs = jobs,
    });
}

fn runShpInit(shell: []const u8, no_comms: bool) !void {
    if (shell.len > 0) {
        try shp.run(.{ .init_shell = shell, .no_comms = no_comms });
    } else {
        print("Error: shell name required (bash, zsh, fish)\n", .{});
    }
}

// ============================================================================
// POP handlers
// ============================================================================

fn runPopNotify(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, message: []const u8) !void {
    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    var buf: [4096]u8 = undefined;

    // Determine target UUID: explicit > current pane
    var target_uuid: ?[]const u8 = null;
    if (uuid.len > 0) {
        target_uuid = uuid;
    } else {
        target_uuid = std.posix.getenv("HEXE_PANE_UUID");
    }

    if (target_uuid) |t| {
        const timeout_ms = if (timeout > 0) timeout else 3000; // Default 3 seconds
        const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pop_notify\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"timeout_ms\":{d}}}", .{ t, message, timeout_ms });
        try conn.sendLine(msg);
    } else {
        print("Error: --uuid required (or run inside hexe mux)\n", .{});
        return;
    }

    var resp_buf: [1024]u8 = undefined;
    if (try conn.recvLine(&resp_buf)) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "error")) {
                if (parsed.value.object.get("message")) |m| {
                    print("Error: {s}\n", .{m.string});
                }
            }
        }
    }
}

fn runPopConfirm(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, message: []const u8) !void {
    if (message.len == 0) {
        print("Error: message is required\n", .{});
        return;
    }

    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    var buf: [4096]u8 = undefined;

    // Determine target UUID
    var target_uuid: ?[]const u8 = null;
    if (uuid.len > 0) {
        target_uuid = uuid;
    } else {
        target_uuid = std.posix.getenv("HEXE_PANE_UUID");
    }

    if (target_uuid) |t| {
        if (timeout > 0) {
            const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pop_confirm\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"timeout_ms\":{d}}}", .{ t, message, timeout });
            try conn.sendLine(msg);
        } else {
            const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pop_confirm\",\"uuid\":\"{s}\",\"message\":\"{s}\"}}", .{ t, message });
            try conn.sendLine(msg);
        }
    } else {
        print("Error: --uuid required (or run inside hexe mux)\n", .{});
        return;
    }

    // Wait for response (blocking)
    var resp_buf: [1024]u8 = undefined;
    if (try conn.recvLine(&resp_buf)) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch {
            std.process.exit(1);
        };
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "error")) {
                if (parsed.value.object.get("message")) |m| {
                    print("Error: {s}\n", .{m.string});
                }
                std.process.exit(1);
            } else if (std.mem.eql(u8, t.string, "pop_response")) {
                if (parsed.value.object.get("confirmed")) |conf| {
                    if (conf == .bool and conf.bool) {
                        std.process.exit(0); // Confirmed
                    }
                }
                std.process.exit(1); // Cancelled, timeout, or not confirmed
            }
        }
    }
    std.process.exit(1);
}

fn runPopChoose(allocator: std.mem.Allocator, uuid: []const u8, timeout: i64, items: []const u8, message: []const u8) !void {
    if (items.len == 0) {
        print("Error: --items is required\n", .{});
        return;
    }

    const socket_path = try ipc.getSesSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = ipc.Client.connect(socket_path) catch |err| {
        if (err == error.ConnectionRefused or err == error.FileNotFound) {
            print("ses daemon is not running\n", .{});
            return;
        }
        return err;
    };
    defer client.close();

    var conn = client.toConnection();
    var buf: [8192]u8 = undefined;

    // Determine target UUID
    var target_uuid: ?[]const u8 = null;
    if (uuid.len > 0) {
        target_uuid = uuid;
    } else {
        target_uuid = std.posix.getenv("HEXE_PANE_UUID");
    }

    if (target_uuid) |t| {
        // Build items JSON array from comma-separated string
        var items_json: std.ArrayList(u8) = .empty;
        defer items_json.deinit(allocator);
        try items_json.appendSlice(allocator, "[");

        var it = std.mem.splitScalar(u8, items, ',');
        var first = true;
        while (it.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " ");
            if (trimmed.len > 0) {
                if (!first) try items_json.appendSlice(allocator, ",");
                try items_json.appendSlice(allocator, "\"");
                try items_json.appendSlice(allocator, trimmed);
                try items_json.appendSlice(allocator, "\"");
                first = false;
            }
        }
        try items_json.appendSlice(allocator, "]");

        const title = if (message.len > 0) message else "Select option";
        if (timeout > 0) {
            const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pop_choose\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"items\":{s},\"timeout_ms\":{d}}}", .{ t, title, items_json.items, timeout });
            try conn.sendLine(msg);
        } else {
            const msg = try std.fmt.bufPrint(&buf, "{{\"type\":\"pop_choose\",\"uuid\":\"{s}\",\"message\":\"{s}\",\"items\":{s}}}", .{ t, title, items_json.items });
            try conn.sendLine(msg);
        }
    } else {
        print("Error: --uuid required (or run inside hexe mux)\n", .{});
        return;
    }

    // Wait for response (blocking)
    var resp_buf: [1024]u8 = undefined;
    if (try conn.recvLine(&resp_buf)) |r| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, r, .{}) catch {
            std.process.exit(1);
        };
        defer parsed.deinit();

        if (parsed.value.object.get("type")) |t| {
            if (std.mem.eql(u8, t.string, "error")) {
                if (parsed.value.object.get("message")) |m| {
                    print("Error: {s}\n", .{m.string});
                }
                std.process.exit(1);
            } else if (std.mem.eql(u8, t.string, "pop_response")) {
                if (parsed.value.object.get("selected")) |sel| {
                    if (sel == .integer) {
                        print("{d}\n", .{sel.integer}); // Output selected index
                        std.process.exit(0);
                    }
                }
                std.process.exit(1); // Cancelled or timeout
            }
        }
    }
    std.process.exit(1);
}
