const std = @import("std");

pub fn printInit(stdout: std.fs.File, no_comms: bool) !void {
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

    if (no_comms) return;

    try stdout.writeAll(
        \\# Hexe shell->mux communication hooks (Zsh)
        \\__hexe_last_cmd=""
        \\__hexe_start=""
        \\
        \\__hexe_exit_intent() {
        \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || return 0
        \\    hexe shp exit-intent >/dev/null 2>/dev/null
        \\    return $?
        \\}
        \\
        \\__hexe_preexec_capture() {
        \\    __hexe_last_cmd="$1"
        \\    __hexe_start=$(date +%s%3N)
        \\    hexe shp shell-event --phase=start --running --started-at=$__hexe_start --cmd="$__hexe_last_cmd" --cwd="$PWD" --jobs=${(M)#jobstates} >/dev/null 2>/dev/null
        \\}
        \\
        \\__hexe_precmd_send() {
        \\    local exit_status=$?
        \\    [[ -n "$HEXE_MUX_SOCKET" && -n "$HEXE_PANE_UUID" ]] || { unset __hexe_start; return 0; }
        \\    # OSC 7 cwd sync
        \\    printf '\033]7;file://%s%s\007' "${HOST:-localhost}" "$PWD" 2>/dev/null
        \\    hexe shp shell-event --phase=end --cmd="$__hexe_last_cmd" --status=$exit_status --cwd="$PWD" --jobs=${(M)#jobstates} >/dev/null 2>/dev/null
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
