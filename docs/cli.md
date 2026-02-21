# CLI reference

All commands accept `--instance <name>` (or `-I <name>`) to target a named instance. See [instances](instances.md).

---

## hexe mux

```sh
hexe mux new [--name <name>] [--debug] [--logfile <path>] [--test-only]
```
Start a new mux session. `--test-only` starts an isolated stack with a generated instance name.

```sh
hexe mux attach <name-or-uuid-prefix>
```
Attach to an existing session.

```sh
hexe mux float [options]
```
Spawn a one-off floating pane.

| Flag | Description |
|---|---|
| `--command <cmd>` | Command to run |
| `--title <text>` | Border title |
| `--cwd <path>` | Working directory |
| `--size WxH,X,Y` | Size (%) and position (%) |
| `--focus` | Focus the float immediately |
| `--isolation <profile>` | none / minimal / default / sandbox / full |
| `--key <key>` | Key sent to pane on dismiss |
| `--result-file <path>` | Write exit output here |
| `--pass-env` | Pass current environment |
| `--extra-env K=V` | Additional env vars |

```sh
hexe mux notify <message> [--uuid <pane>] [--broadcast] [--last]
```
Send a notification to a pane or broadcast to all.

```sh
hexe mux send <text> [--uuid <pane>] [--name <name>] [--target <t>]
```
Send keystrokes to a pane.

```sh
hexe mux focus left|right|up|down [--uuid <pane>]
```
Move pane focus directionally (useful for editor integration).

---

## hexe ses

```sh
hexe ses daemon [--debug] [--logfile <path>] [--foreground]
```
Start the session daemon. Usually started automatically by `hexe mux new`.

```sh
hexe ses list [--details] [--json]
```
List all sessions with their panes.

```sh
hexe ses status
```
Show daemon version and uptime.

```sh
hexe ses kill <uuid>
```
Kill a detached session and its panes.

```sh
hexe ses clear [--force]
```
Kill all detached sessions.

```sh
hexe ses export <uuid>
```
Export session layout and pane state as JSON.

```sh
hexe ses stats
```
Show resource usage for all sessions and pods.

---

## hexe pod

```sh
hexe pod list [--where <path>] [--alive] [--json]
```
List discoverable pods.

```sh
hexe pod new [--name <name>] [--shell <shell>] [--cwd <path>] [--alias]
```
Create a standalone pod not attached to any session.

```sh
hexe pod attach <uuid-or-name> [--detach-key <key>]
```
Raw TTY attach to a pod (like `screen -r` but for a single PTY).

```sh
hexe pod send <text> [--uuid <u>] [--name <n>] [--enter] [--ctrl]
```
Send text or keystrokes to a pod.

```sh
hexe pod kill <uuid-or-name> [--signal <sig>] [--force]
```
Kill a pod.

```sh
hexe pod gc [--dry-run]
```
Remove stale pod socket/metadata files left by crashed pods.

---

## hexe shp

```sh
hexe shp init bash|zsh|fish
```
Print shell initialization code. Eval this in your shell RC file:

```sh
eval "$(hexe shp init bash)"
```

```sh
hexe shp prompt [--status <n>] [--duration <ms>] [--jobs <n>] [--right] [--shell <sh>]
```
Render the prompt for the given context. Called automatically by the shell integration.

---

## hexe config

```sh
hexe config validate
```
Parse and validate `~/.config/hexe/init.lua` without starting anything.

---

## hexe com

```sh
hexe com
```
Print a tree of all running mux sessions, tabs, panes, and pods.

---

## Global flags

| Flag | Description |
|---|---|
| `-I / --instance <name>` | Target named instance |
| `--debug` | Enable debug logging |
| `--logfile <path>` | Write logs to file |
