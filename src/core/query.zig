const std = @import("std");
const config = @import("config.zig");

/// Unified queryable state for a single pane at a point in time.
/// Populated by MUX from its state (or by SHP from CLI args for prompt mode).
/// Used by: condition evaluation (when blocks), segment rendering, keybinding filtering.
pub const PaneQuery = struct {
    // -- mux (layout) --
    is_float: bool = false,
    is_split: bool = true,
    float_key: u8 = 0,
    float_sticky: bool = false,
    float_exclusive: bool = false,
    float_per_cwd: bool = false,
    float_global: bool = false,
    float_isolated: bool = false,
    float_destroyable: bool = false,
    tab_count: u16 = 1,
    active_tab: u16 = 0,

    // -- pod (pty state) --
    alt_screen: bool = false,
    fg_process: ?[]const u8 = null,
    fg_pid: ?i32 = null,

    // -- shp (shell integration) --
    cwd: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    exit_status: ?i32 = null,
    cmd_duration_ms: ?u64 = null,
    jobs: u16 = 0,
    shell_running: bool = false,
    shell_running_cmd: ?[]const u8 = null,
    shell_started_at_ms: ?u64 = null,

    // -- ses (session) --
    session_name: []const u8 = "",
    session_duration_ms: u64 = 0,

    // -- timing --
    now_ms: u64 = 0,
};

/// Evaluate a single token string against a PaneQuery.
/// Tokens are simple boolean predicates with optional "not_" prefix.
pub fn evalToken(q: *const PaneQuery, tok: []const u8) bool {
    // Shell / pod state tokens (previously hexe_shp)
    if (eql(tok, "process_running")) return q.shell_running;
    if (eql(tok, "not_process_running")) return !q.shell_running;
    if (eql(tok, "alt_screen")) return q.alt_screen;
    if (eql(tok, "not_alt_screen")) return !q.alt_screen;
    if (eql(tok, "jobs_nonzero")) return q.jobs > 0;
    if (eql(tok, "has_last_cmd")) return q.last_command != null and q.last_command.?.len > 0;
    if (eql(tok, "last_status_nonzero")) return (q.exit_status orelse 0) != 0;

    // Mux layout tokens (previously hexe_mux)
    if (eql(tok, "focus_float")) return q.is_float;
    if (eql(tok, "focus_split")) return q.is_split;
    if (eql(tok, "adhoc_float")) return q.is_float and q.float_key == 0;
    if (eql(tok, "named_float")) return q.is_float and q.float_key != 0;
    if (eql(tok, "float_destroyable")) return q.is_float and q.float_destroyable;
    if (eql(tok, "float_exclusive")) return q.is_float and q.float_exclusive;
    if (eql(tok, "float_sticky")) return q.is_float and q.float_sticky;
    if (eql(tok, "float_per_cwd")) return q.is_float and q.float_per_cwd;
    if (eql(tok, "float_global")) return q.is_float and q.float_global;
    if (eql(tok, "float_isolated")) return q.is_float and q.float_isolated;
    if (eql(tok, "tabs_gt1")) return q.tab_count > 1;
    if (eql(tok, "tabs_eq1")) return q.tab_count == 1;

    // fg_process matching: "fg:<name>" checks basename
    if (std.mem.startsWith(u8, tok, "fg:")) {
        const want = tok[3..];
        const proc = q.fg_process orelse return false;
        return eql(proc, want);
    }

    // Negated fg_process: "not_fg:<name>"
    if (std.mem.startsWith(u8, tok, "not_fg:")) {
        const want = tok[7..];
        const proc = q.fg_process orelse return true;
        return !eql(proc, want);
    }

    return false;
}

/// Evaluate a WhenTokens expression (AND/OR groups of tokens).
pub fn evalTokens(q: *const PaneQuery, expr: config.WhenTokens) bool {
    if (expr.any) |groups| {
        for (groups) |g| {
            var ok = true;
            for (g.tokens) |t| {
                if (!evalToken(q, t)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
    if (expr.all) |tokens| {
        for (tokens) |t| {
            if (!evalToken(q, t)) return false;
        }
        return true;
    }
    return true;
}

/// Evaluate a single WhenDef clause (token-based only; bash/lua handled by caller).
/// Returns false if any token provider fails. Returns true if no token providers set.
pub fn evalWhenClause(q: *const PaneQuery, w: config.WhenDef) bool {
    // All token namespaces resolve against the same PaneQuery
    if (w.hexe_shp) |tokens| {
        if (!evalTokens(q, tokens)) return false;
    }
    if (w.hexe_mux) |tokens| {
        if (!evalTokens(q, tokens)) return false;
    }
    if (w.hexe_ses) |tokens| {
        if (!evalTokens(q, tokens)) return false;
    }
    if (w.hexe_pod) |tokens| {
        if (!evalTokens(q, tokens)) return false;
    }
    return true;
}

/// Evaluate a full WhenDef (handles DNF "any" clauses).
/// Only evaluates token conditions; bash/lua conditions are not handled here
/// (caller should check those separately with caching).
pub fn evalWhen(q: *const PaneQuery, w: config.WhenDef) bool {
    if (w.any) |clauses| {
        for (clauses) |c| {
            if (evalWhenClause(q, c)) return true;
        }
        return false;
    }
    return evalWhenClause(q, w);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
