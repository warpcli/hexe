# Architecture

Hexa splits the terminal multiplexer into three cooperating processes. Each owns a single responsibility and can be restarted independently.

```
┌──────────────┐        ┌──────────────┐        ┌──────────────┐
│   hexe mux   │◄──────►│   hexe ses   │◄──────►│   hexe pod   │
│  (UI layer)  │  CTL   │  (registry)  │  CTL   │ (per pane)   │
│              │  VT ──►│              │  VT ──►│              │
└──────────────┘        └──────────────┘        └──────────────┘
```

---

## hexe mux — the UI

Renders the terminal. Handles keybindings, tabs, splits, floats, popups, and the status bar.

- Owns the Ghostty VT state machine per pane (parses escape sequences, tracks cursor, cells)
- Reads terminal input, routes keystrokes to the active pane or triggers mux actions
- Safe to kill and restart — your shells and state survive

When mux exits, pods keep running. When you start a new mux, it reattaches.

## hexe ses — the registry

A persistent daemon that tracks all sessions, panes, and their layouts.

- Knows which pods exist and where their sockets are
- Stores detached session layouts so mux can restore them on reattach
- Periodically persists state to disk so even a ses crash is recoverable
- Multiplexes VT output: receives a tagged byte stream from pods, routes each chunk to the correct mux pane

One ses daemon per instance. It starts automatically when you launch a mux.

## hexe pod — the PTY owner

One pod per pane. Owns the PTY master file descriptor and the shell process inside it.

- Spawns and holds the shell
- Drains PTY output continuously so the shell never blocks (even when detached)
- Buffers scrollback so reattaching replays missed output
- Can run in an isolated namespace (cgroups, bind mounts) — see [isolation](isolation.md)

Pods are the only durable part of the system. Everything else can restart around them.

---

## Communication channels

Between each pair of processes there are two channels:

- **CTL** (control): request/response for metadata (pane info, CWD, session state)
- **VT** (terminal data): streaming byte channel for PTY output, tagged by pane ID

All panes within a session share a single VT pipe between mux and ses, multiplexed via a small header (pane ID + byte length) per chunk.

---

## IPC sockets

Sockets live under `$XDG_RUNTIME_DIR/hexe/` (fallback: `/tmp/hexe/`).

Named instances use a subdirectory: `$XDG_RUNTIME_DIR/hexe/<instance>/`.

See [instances](instances.md) for running multiple independent stacks.

---

## Reattach flow

1. You run `hexe mux attach <session>`
2. Mux connects to ses and reads the stored layout
3. For each pane, mux adopts the pod (subscribes to its VT output)
4. Pod replays buffered scrollback into the mux VT stream
5. Ghostty VT rebuilds the terminal state from the replayed bytes
6. You see your panes as you left them

---

## Crash recovery

- **Mux crash**: pods keep running, ses keeps running. Reattach with `hexe mux attach`.
- **Ses crash**: pods keep running. Ses restarts and reads persisted state from disk. Mux reconnects.
- **Pod crash**: pane shows a "Shell exited" popup. Other panes are unaffected.
