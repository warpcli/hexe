# Architecture

Hexa is a terminal multiplexer built around four cooperating processes communicating over Unix domain sockets using a binary protocol. All control messages are packed structs with a 6-byte envelope. VT (terminal I/O) data flows on dedicated channels, never mixed with control traffic.

```
┌────────────────────────────────────────────────────────────────┐
│                           TERMINAL                             │
│                    (user's terminal emulator)                  │
└───────────────────────────────┬────────────────────────────────┘
                                │ raw tty (stdin/stdout)
                                │
┌───────────────────────────────┴────────────────────────────────┐
│                             MUX                                │
│                                                                │
│  Renderer + input handler. Manages tabs, splits, floats.       │
│  Talks ONLY to SES. Never connects to POD directly.           │
│                                                                │
│  2 outbound connections to ses.sock:                           │
│    Channel 1 -- control (binary structs, non-blocking)         │
│    Channel 2 -- VT data (multiplexed by pane_id)               │
└───────────────┬────────────────────────────┬───────────────────┘
                │ [1] CTL                    │ [2] VT
                │                            │
┌───────────────┴────────────────────────────┴───────────────────┐
│                             SES                                │
│                                                                │
│  Session daemon. Routes VT between MUX and PODs.               │
│  Manages pane lifecycle, persistence, detach/reattach.         │
│                                                                │
│  Listens: ses.sock                                             │
│  Routing table: pane_id (u16) --> POD VT fd                    │
│                                                                │
└───────┬──────────────────┬──────────────────┬──────────────────┘
        │                  │                  │
     [3] VT            [3] VT            [3] VT
     [4] CTL           [4] CTL           [4] CTL
        │                  │                  │
   ┌────┴────┐        ┌────┴────┐        ┌────┴────┐
   │  POD-0  │        │  POD-1  │        │  POD-2  │
   │  PTY    │        │  PTY    │        │  PTY    │
   │  backlog│        │  backlog│        │  backlog│
   │  /proc  │        │  /proc  │        │  /proc  │
   └────┬────┘        └────┬────┘        └────┬────┘
        │ PTY              │ PTY              │ PTY
        v                  v                  v
      SHELL              SHELL              SHELL
        │                  │
        └──> SHP ──[5]──> POD  (per-command, short-lived)
```

---

## Components

| Component | Role | Lifetime | Socket |
|---|---|---|---|
| **MUX** | Terminal UI, input, layout | User session | None (client only) |
| **SES** | Session daemon, VT router | Persistent daemon | `ses.sock` (server) |
| **POD** | Per-pane PTY, backlog, metadata | Until shell exits | `pod-<UUID>.sock` (server) |
| **SHP** | Shell hooks, prompt, cmd metadata | Per-command | Connects to POD |

All sockets live under `${XDG_RUNTIME_DIR:-/tmp}/hexe/`. Named instances use a subdirectory: `${XDG_RUNTIME_DIR}/hexe/<instance>/`. See [instances](instances.md).

---

## hexe mux — the UI

Renders the terminal. Handles keybindings, tabs, splits, floats, popups, and the status bar.

- Owns the Ghostty VT state machine per pane (parses escape sequences, tracks cursor, cells)
- Reads terminal input, routes keystrokes to the active pane or triggers mux actions
- Connects to SES only — never directly to a POD
- Safe to kill and restart — your shells and state survive

## hexe ses — the registry

A persistent daemon that tracks all sessions, panes, and their layouts.

- Routes VT bytes between MUX and PODs without inspection — a stateless router on the hot path
- Stores detached session layouts so MUX can restore them on reattach
- Periodically persists state to disk so even a SES crash is recoverable
- Starts automatically when you launch a mux; one daemon per instance

## hexe pod — the PTY owner

One pod per pane. Owns the PTY master file descriptor and the shell process inside it.

- Spawns and holds the shell
- Drains PTY output continuously so the shell never blocks (even when detached)
- Buffers a 4MB ring buffer of scrollback for reattach replay
- Monitors `/proc/<pid>/cwd`, `/proc/<pid>/stat` to detect CWD and fg process changes
- Can run in an isolated namespace (cgroups, bind mounts) — see [isolation](isolation.md)

Pods are the only durable part of the system. Everything else can restart around them.

## hexe shp — the shell hook

A short-lived helper that runs inside the shell (via precmd/preexec hooks).

- Reports shell events (command start, command end, exit status, duration) to the pod
- Serves prompt render requests from the pod
- Connects to `pod-<UUID>.sock` using `HEXE_POD_SOCKET` from the environment

---

## The 5 channels

```
┌─────────┬─────────────┬────────────────────────────────────────────────┐
│ Channel │ Endpoints   │ Purpose                                        │
├─────────┼─────────────┼────────────────────────────────────────────────┤
│   [1]   │ MUX <-> SES │ Control: create/destroy panes, detach,         │
│         │             │ reattach, sync state, popups, notifications    │
├─────────┼─────────────┼────────────────────────────────────────────────┤
│   [2]   │ MUX <-> SES │ VT data: multiplexed by pane_id               │
│         │             │ Input (MUX->SES), Output (SES->MUX)            │
├─────────┼─────────────┼────────────────────────────────────────────────┤
│   [3]   │ SES <-> POD │ VT data: one fd per POD, no pane_id needed    │
│         │             │ Raw PTY I/O + backlog replay                   │
├─────────┼─────────────┼────────────────────────────────────────────────┤
│   [4]   │ POD -> SES  │ Control: cwd/fg/title changes, shell events,   │
│         │             │ process exit notifications                     │
├─────────┼─────────────┼────────────────────────────────────────────────┤
│   [5]   │ SHP <-> POD │ Control: shell command metadata, prompt        │
│         │             │ request/response                               │
└─────────┴─────────────┴────────────────────────────────────────────────┘
```

---

## Wire formats

### Control envelope (channels [1] [4] [5])

Every control message on every channel uses the same 6-byte header:

```
byte:  0     1     2     3     4     5
     ┌─────┬─────┬─────┬─────┬─────┬─────┬─ ─ ─ ─ ─ ─ ─ ─┐
     │  msg_type  │        payload_len     │  payload ...   │
     │   (u16)    │          (u32)         │                │
     └─────┴─────┴─────┴─────┴─────┴─────┴─ ─ ─ ─ ─ ─ ─ ─┘
     ├── 2 bytes ─┤├──────── 4 bytes ──────┤├── N bytes ────┤
```

### MUX VT frame (channel [2])

Multiplexed VT data between MUX and SES. `pane_id` identifies which pane the frame belongs to.

```
byte:  0     1     2     3     4     5     6
     ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─ ─ ─ ─ ─ ─┐
     │  pane_id   │type │          len          │ VT bytes.. │
     │   (u16)    │(u8) │         (u32)         │            │
     └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─ ─ ─ ─ ─ ─┘
     ├── 2B ──┤├1B┤├─────────── 4B ────────────┤├─ N bytes ─┤

     frame_type:
       0x01 = output       (SES->MUX)  PTY output
       0x02 = input        (MUX->SES)  keystrokes
       0x03 = resize       (MUX->SES)  payload = [cols:u16][rows:u16]
       0x04 = backlog_end  (SES->MUX)  len=0, signals replay complete
```

### POD VT frame (channel [3])

Direct VT between SES and a single POD. No `pane_id` needed — the fd IS the pane.

```
byte:  0     1     2     3     4
     ┌─────┬─────┬─────┬─────┬─────┬─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
     │type │          len          │ VT bytes ...        │
     │(u8) │         (u32)         │                     │
     └─────┴─────┴─────┴─────┴─────┴─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
     ├1B┤├─────────── 4B ──────────┤├──── N bytes ───────┤

     Same frame_types as channel [2].
```

---

## Message types

### Channel [1] — MUX <-> SES control (0x01xx)

```
MsgType              Value   Direction  Description
───────────────────  ──────  ─────────  ──────────────────────────────────
register             0x0100  MUX->SES   Register + name bytes
registered           0x0101  SES->MUX   Registered + resolved session name
create_pane          0x0102  MUX->SES   CreatePane + shell + cwd + sticky
pane_created         0x0103  SES->MUX   PaneCreated + socket_path
destroy_pane         0x0104  MUX->SES   PaneUuid
detach               0x0105  MUX->SES   Detach + layout JSON
reattach             0x0106  MUX->SES   Reattach + session prefix
session_state        0x0107  SES->MUX   (layout data)
layout_sync          0x0108  MUX->SES   (layout update)
notify               0x0109  SES->MUX   Notify + message
pop_confirm          0x010A  SES->MUX   PopConfirm + message
pop_choose           0x010B  SES->MUX   PopChoose + title + items
pop_response         0x010C  MUX->SES   PopResponse
disconnect           0x010D  MUX->SES   Disconnect
sync_state           0x010E  MUX->SES   SyncState + layout JSON
orphan_pane          0x010F  MUX->SES   PaneUuid
list_orphaned        0x0110  MUX->SES   (empty)
adopt_pane           0x0111  MUX->SES   PaneUuid
kill_pane            0x0112  MUX->SES   PaneUuid
set_sticky           0x0113  MUX->SES   SetSticky + pwd
find_sticky          0x0114  MUX->SES   FindSticky + pwd
pane_info            0x0115  MUX->SES   PaneUuid
update_pane_aux      0x0116  MUX->SES   UpdatePaneAux + fields
update_pane_name     0x0117  MUX->SES   UpdatePaneName + name
update_pane_shell    0x0118  MUX->SES   UpdatePaneShell + fields
get_pane_cwd         0x0119  MUX->SES   GetPaneCwd
list_sessions        0x011A  MUX->SES   (empty)
ping                 0x011B  MUX->SES   (empty)
pong                 0x011C  SES->MUX   (empty)
ok                   0x011D  SES->MUX   (ack)
error                0x011E  SES->MUX   (error response)
pane_found           0x011F  SES->MUX   PaneCreated
pane_not_found       0x0120  SES->MUX   (empty)
orphaned_panes       0x0121  SES->MUX   (list)
sessions_list        0x0122  SES->MUX   (list)
session_reattached   0x0123  SES->MUX   SessionReattached + JSON + UUIDs
session_detached     0x0124  SES->MUX   (empty)
send_keys            0x0125  CLI->SES   SendKeys + data
broadcast_notify     0x0126  CLI->SES   Notify + message
targeted_notify      0x0127  CLI->SES   Notify + message
status               0x0128  CLI->SES   (status query)
focus_move           0x0129  CLI->SES   FocusMove
exit_intent          0x012A  SES->MUX   ExitIntent
exit_intent_result   0x012B  MUX->SES   ExitIntentResult
float_request        0x012C  SES->MUX   FloatRequest + cmd + env
float_created        0x012D  MUX->SES   FloatCreated
float_result         0x012E  MUX->SES   FloatResult + output
pane_exited          0x012F  SES->MUX   PaneExited
replay_backlogs      0x0130  MUX->SES   (empty)
kill_session         0x0131  CLI->SES   PaneUuid
clear_sessions       0x0132  CLI->SES   (empty)
clear_orphaned_panes 0x0133  CLI->SES   (empty)
get_layout           0x0134  CLI->SES   GetLayout
apply_layout         0x0135  SES->MUX   ApplyLayout + tree JSON
get_session_state    0x0136  CLI->SES   PaneUuid
```

### Channel [4] — POD -> SES control (0x04xx)

```
MsgType              Value   Direction  Description
───────────────────  ──────  ─────────  ──────────────────────────────────
cwd_changed          0x0400  POD->SES   CwdChanged + path
fg_changed           0x0401  POD->SES   FgChanged + process name
shell_event          0x0402  POD->SES   ShellEvent + cmd + cwd
title_changed        0x0403  POD->SES   TitleChanged + title
bell                 0x0404  POD->SES   PaneUuid
exited               0x0405  POD->SES   Exited
query_state          0x0406  SES->POD   (request metadata)
pod_register         0x0407  POD->SES   (registration ack)
```

### Channel [5] — SHP <-> POD control (0x05xx)

```
MsgType              Value   Direction  Description
───────────────────  ──────  ─────────  ──────────────────────────────────
shp_shell_event      0x0500  SHP->POD   ShpShellEvent + cmd + cwd
shp_prompt_req       0x0501  POD->SHP   (request prompt data)
shp_prompt_resp      0x0502  SHP->POD   (prompt response)
```

---

## Handshake protocol

Each socket accepts multiple channel types. The first byte after `connect()` identifies the channel.

### ses.sock (SES listens)

```
Client sends first byte:

  0x01 --> MUX control channel [1]
           Next: Register struct (session_id + keepalive + name)
           Then: bidirectional control messages

  0x02 --> MUX VT data channel [2]
           Next: 32-byte session_id (hex, to pair with channel [1])
           Then: bidirectional MuxVtHeader frames

  0x03 --> POD control uplink [4]
           Next: 16 binary bytes (UUID, decoded from 32 hex chars)
           Then: POD sends metadata, SES sends queries

  0x04 --> CLI tool connection
           Next: control message (send_keys, notify, focus_move, etc.)
           Then: response, close
```

### pod-\<UUID\>.sock (POD listens)

```
Client sends first byte:

  0x01 --> SES VT data channel [3]
           Next: bidirectional VT frames immediately
           POD replays backlog, then streams live output

  0x02 --> SHP control channel [5]
           Next: SHP sends shell_event or prompt_req
           Short-lived connection (per-command)
```

---

## VT data flow

### User types a key

```
TERMINAL
   │ keystroke
   v
  MUX ─── stdin read
   │
   │ writeMuxVt(vt_fd, pane_id=3, type=INPUT, "a")
   │
   │ Wire on channel [2]:
   │ ┌────────┬────┬───────┬───┐
   │ │pane=3  │0x02│ len=1 │ a │
   │ └────────┴────┴───────┴───┘
   v
  SES ─── reads MuxVtHeader, extracts pane_id=3
   │
   │ Looks up: pane_id_to_pod_vt[3] -> pod_fd
   │ Writes raw byte "a" to pod_fd
   v
  POD ─── reads from vt_fd
   │
   │ Writes "a" to PTY master
   v
SHELL ─── receives "a" on PTY slave
```

### Shell produces output

```
SHELL ─── writes "hello\n" to PTY slave
   │
   v
  POD ─── reads "hello\n" from PTY master
   │
   │ Writes to vt_fd (connected to SES):
   │ ┌────┬────────┬─────────┐
   │ │0x01│  len=6 │ hello\n │   (5-byte header, channel [3])
   │ └────┴────────┴─────────┘
   v
  SES ─── reads from pod_vt_fd
   │
   │ Looks up: pod_vt_to_pane_id[pod_vt_fd] -> pane_id=3
   │ Writes MuxVtHeader to mux_vt_fd:
   │ ┌────────┬────┬────────┬─────────┐
   │ │pane=3  │0x01│  len=6 │ hello\n │   (7-byte header, channel [2])
   │ └────────┴────┴────────┴─────────┘
   v
  MUX ─── reads MuxVtHeader from vt_fd
   │
   │ Finds pane by pane_id=3
   │ Feeds "hello\n" to pane.vt emulator
   │ Renders to terminal
   v
TERMINAL
```

### Resize

```
TERMINAL resize event (SIGWINCH)
   │
   v
  MUX ─── recalculates layout
   │
   │ For each pane, writes to channel [2]:
   │ ┌────────┬────┬───────┬──────┬──────┐
   │ │pane=3  │0x03│ len=4 │ cols │ rows │
   │ └────────┴────┴───────┴──────┴──────┘
   v
  SES ─── reads MuxVtHeader, sees type=RESIZE
   │
   │ Writes to pod_vt_fd:
   │ ┌────┬───────┬──────┬──────┐
   │ │0x03│ len=4 │ cols │ rows │   (channel [3])
   │ └────┴───────┴──────┴──────┘
   v
  POD ─── reads resize frame
   │
   │ Calls ioctl(pty_master, TIOCSWINSZ, ...)
   v
SHELL ─── receives SIGWINCH
```

---

## Control flow examples

### Pane creation

```
  MUX                           SES                           POD
   │                             │                             │
   │ create_pane                 │                             │
   │ {shell="/bin/bash",         │                             │
   │  cwd="/home/user"}          │                             │
   ├──────────[1]───────────────>│                             │
   │                             │ fork + exec                 │
   │                             │ "hexe pod daemon            │
   │                             │   --uuid <UUID>"            │
   │                             ├──────────spawn─────────────>│
   │                             │                             │
   │                             │        stdout: {"pid":1234} │
   │                             │<────────────────────────────┤
   │                             │                             │
   │                             │ connect pod-<UUID>.sock     │
   │                             │ send handshake 0x01         │
   │                             ├──────────[3]───────────────>│
   │                             │          accepts channel [3]│
   │                             │<────────────────────────────┤
   │                             │                             │
   │                             │          connect ses.sock   │
   │                             │          send 0x03 + UUID   │
   │                             │<─────────[4]────────────────┤
   │                             │          (channel [4] ready)│
   │                             │                             │
   │        pane_created         │                             │
   │        {uuid, pane_id=3,    │                             │
   │         pid=1234}           │                             │
   │<───────────[1]──────────────┤                             │
   │                             │                             │
   │ VT data flows via [2]<->[3] │                             │
```

### Detach and reattach

```
  MUX-1                         SES                          PODs
   │                             │                             │
   │ detach                      │                             │
   │ {session_id, layout_json}   │                             │
   ├──────────[1]───────────────>│                             │
   │                             │ Store layout                │
   │                             │ Mark panes "detached"       │
   │                             │                             │
   │ disconnect                  │                             │
   ├──────────[1]───────────────>│                             │
   │                             │                             │
   X (MUX exits)                 │                             │
                                 │                             │
   PODs keep running ────────────┼────────────────────────────>│
   SES keeps channels [3][4] ───>│                             │
                                 │                             │
  MUX-2 (new terminal)          │                             │
   │                             │                             │
   │ register (new session_id)   │                             │
   ├──────────[1]───────────────>│                             │
   │                             │                             │
   │ reattach {prefix="pika"}    │                             │
   ├──────────[1]───────────────>│                             │
   │                             │ Find matching session       │
   │                             │ Restore layout              │
   │                             │                             │
   │        session_reattached   │                             │
   │        {layout_json,        │                             │
   │         pane UUIDs,         │                             │
   │         pane_ids}           │                             │
   │<───────────[1]──────────────┤                             │
   │                             │                             │
   │ Open channel [2] (VT)       │                             │
   ├──────────[2]───────────────>│                             │
   │                             │                             │
   │                             │ Reconnect [3] to each POD  │
   │                             ├──────────[3]───────────────>│
   │                             │                             │
   │                             │     POD replays backlog     │
   │                             │<─────────[3]────────────────┤
   │                             │                             │
   │  backlog frames             │                             │
   │  (pane_id, type=OUTPUT)     │                             │
   │<───────────[2]──────────────┤                             │
   │                             │                             │
   │  backlog_end per pane       │                             │
   │<───────────[2]──────────────┤                             │
   │                             │                             │
   │  Live data resumes          │                             │
```

### Shell event (SHP -> POD -> SES -> MUX)

```
  SHELL              SHP               POD               SES              MUX
   │                  │                  │                 │                │
   │ Command finishes │                  │                 │                │
   │ (precmd hook)    │                  │                 │                │
   ├─────────────────>│                  │                 │                │
   │                  │                  │                 │                │
   │                  │ connect          │                 │                │
   │                  │ pod-UUID.sock    │                 │                │
   │                  │ send 0x02        │                 │                │
   │                  ├──────[5]────────>│                 │                │
   │                  │                  │                 │                │
   │                  │ shp_shell_event  │                 │                │
   │                  │ {phase=END,      │                 │                │
   │                  │  status=0,       │                 │                │
   │                  │  duration=1234,  │                 │                │
   │                  │  cmd="make"}     │                 │                │
   │                  ├──────[5]────────>│                 │                │
   │                  │                  │                 │                │
   │                  X (SHP exits)      │ Stores metadata │                │
   │                  │                  │                 │                │
   │                  │                  │ shell_event     │                │
   │                  │                  ├──────[4]───────>│                │
   │                  │                  │                 │                │
   │                  │                  │                 │ shell_event    │
   │                  │                  │                 ├──────[1]──────>│
   │                  │                  │                 │                │
   │                  │                  │                 │                │ Status bar:
   │                  │                  │                 │                │ "make ok 1.2s"
```

---

## SES routing tables

SES maintains bidirectional lookup tables to route VT frames:

```
┌───────────────────────────────────────────────────────────────┐
│                        SES State                              │
│                                                               │
│  Clients (per MUX connection):                                │
│  ┌───────────────────────────────────────────────────────┐    │
│  │ session_id  ->  Client {                              │    │
│  │                   mux_ctl_fd: fd_t,    (channel [1])  │    │
│  │                   mux_vt_fd:  fd_t,    (channel [2])  │    │
│  │                   pane_uuids: []uuid,                 │    │
│  │                   keepalive:  bool,                   │    │
│  │                   name:       []u8,                   │    │
│  │                 }                                     │    │
│  └───────────────────────────────────────────────────────┘    │
│                                                               │
│  Panes (per shell):                                           │
│  ┌───────────────────────────────────────────────────────┐    │
│  │ uuid  ->  Pane {                                      │    │
│  │             pane_id:    u16,                           │    │
│  │             pod_vt_fd:  fd_t,    (channel [3])         │    │
│  │             pod_ctl_fd: fd_t,    (channel [4])         │    │
│  │             pod_pid:    pid_t,                         │    │
│  │             state:      PaneState,                     │    │
│  │             session_id: ?[32]u8,                       │    │
│  │           }                                           │    │
│  └───────────────────────────────────────────────────────┘    │
│                                                               │
│  VT routing (fast path):                                      │
│  ┌───────────────────────────────────────────────────────┐    │
│  │ pane_id_to_pod_vt:  HashMap(u16, fd_t)                │    │
│  │ pod_vt_to_pane_id:  HashMap(fd_t, u16)                │    │
│  └───────────────────────────────────────────────────────┘    │
│                                                               │
│  Detached sessions (for reattach):                            │
│  ┌───────────────────────────────────────────────────────┐    │
│  │ session_id  ->  DetachedState {                       │    │
│  │                   layout_json: []u8,                   │    │
│  │                   pane_uuids:  []uuid,                │    │
│  │                   name:        []u8,                   │    │
│  │                 }                                     │    │
│  └───────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────┘
```

---

## POD internals

```
┌──────────────────────────────────────────────────────────────┐
│                      POD Process                             │
│                                                              │
│  OWNS:                                                       │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  PTY master fd           (reads output, writes input)│    │
│  │  4MB ring buffer         (backlog for replay)        │    │
│  │  Child PID               (the shell process)         │    │
│  │  Terminal dimensions     (cols x rows)               │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  MONITORS (from /proc):                                      │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  /proc/<pid>/cwd              -> working directory   │    │
│  │  /proc/<pid>/stat             -> fg process name     │    │
│  │  /proc/<pid>/task/*/children  -> fg PID              │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  RECEIVES (from SHP, channel [5]):                           │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Last command text                                   │    │
│  │  Exit status                                         │    │
│  │  Command duration (ms)                               │    │
│  │  Job count                                           │    │
│  │  Running flag                                        │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  SOCKET: pod-<UUID>.sock                                     │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Accepts:                                            │    │
│  │    0x01 -> SES VT (channel [3]):                     │    │
│  │            Replay backlog, then stream live output    │    │
│  │            Receive input/resize frames               │    │
│  │    0x02 -> SHP control (channel [5]):                │    │
│  │            Receive shell events, respond to prompts  │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  UPLINK: connects to ses.sock (channel [4])                  │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Sends metadata changes:                             │    │
│  │    cwd_changed   (when /proc/<pid>/cwd changes)      │    │
│  │    fg_changed    (when foreground process changes)   │    │
│  │    shell_event   (forwarded from SHP)                │    │
│  │    exited        (when child process exits)          │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  Tick loop (500ms):                                          │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  1. Read /proc/<pid>/cwd                             │    │
│  │  2. If changed -> send cwd_changed on channel [4]    │    │
│  │  3. Read /proc/<pid>/stat                            │    │
│  │  4. If changed -> send fg_changed on channel [4]     │    │
│  │  5. Check child alive (waitpid WNOHANG)              │    │
│  │  6. If exited -> send exited on channel [4], cleanup │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

---

## Pane state machine

```
               create_pane
                   │
                   v
              ┌─────────┐
              │ATTACHED │<──────────────────────────────────┐
              └────┬────┘                                   │
                   │                                        │
      ┌────────────┼────────────┐                           │
      │            │            │                           │
MUX disconnect  orphan_pane  MUX disconnect                 │
(keepalive=true)             (sticky pane)                  │
      │            │            │                           │
      v            │            v                           │
 ┌────────┐        │       ┌────────┐                      │
 │DETACHED│        │       │ STICKY │                      │
 └───┬────┘        │       └───┬────┘                      │
      │            │            │                           │
reattach by         │     find_sticky                      │
session prefix      │     (pwd+key match)                  │
      │            │            │                           │
      v            v            │                           │
 ┌────────┐                     │                           │
 │ORPHANED│                     │                           │
 └───┬────┘                     │                           │
      │                         │                           │
   adopt_pane                   │                           │
      │                         │                           │
      └─────────────────────────┴───────────────────────────┘
```

**States:**
- `attached` — Active pane, owned by a MUX client
- `detached` — Session disconnected with keepalive; grouped for reattach
- `sticky` — Pane bound to a directory+key pair; reused when same context returns
- `orphaned` — No owner; available for any MUX to adopt

---

## MUX pane backends

MUX panes have two possible backends:

```
┌─────────────────────────────────────────────────────────────┐
│  Backend = union(enum) {                                    │
│                                                             │
│    .local -> Pty (MUX owns PTY fd directly)                 │
│             Used for: ad-hoc floats (yazi, fzf)             │
│             I/O: MUX reads/writes PTY master                │
│             No SES routing needed                           │
│             Dies with MUX (not persistent)                  │
│                                                             │
│    .pod  -> { pane_id: u16, vt_fd: fd_t }                   │
│             Used for: tiled panes, persistent floats        │
│             I/O: through channel [2] (via SES)              │
│             Survives MUX detach/reattach                    │
│             Shell runs in separate POD process              │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Non-blocking CTL pattern

Channel [1] (MUX->SES control) uses non-blocking I/O to prevent deadlocks:

```
Problem (if blocking):

  MUX                                SES
   │                                  │
   │ pane_info request (blocking)     │
   ├─────────────────────────────────>│
   │                                  │
   │ ... waiting for response ...     │ VT data for MUX (channel [2])
   │                                  ├── tries to write ──> BLOCKS
   │ can't read VT (blocked on [1])   │   (MUX not reading [2])
   │                                  │
   X DEADLOCK

Solution: fire-and-forget + async response handling

  MUX                                SES
   │                                  │
   │ pane_info request                │
   │ (non-blocking write,             │
   │  don't wait for response)        │
   ├─────────────────────────────────>│
   │                                  │
   │ poll loop continues...           │
   │ reads VT data normally           │ VT data flows fine
   │<─────────────────────────────────┤
   │                                  │
   │ Eventually: CTL fd readable      │
   │ reads pane_info response         │
   │<─────────────────────────────────┤
   │ processes async response         │
```

**Fire-and-forget** (no response expected):
- `sync_state`, `update_pane_name`, `update_pane_shell`
- `get_pane_cwd`, `pane_info` (responses arrive asynchronously)

**Synchronous** (response required, uses `readSyncResponse` which skips stale async responses):
- `create_pane` → `pane_created`
- `reattach` → `session_reattached`
- `adopt_pane` → `pane_found`
- `ping` → `pong`

---

## Process tree

```
Terminal Emulator
 └─ hexe mux              (MUX process, user-facing)
      │
      └─ (connects to ses.sock)
              │
     hexe ses daemon       (SES daemon, long-lived, started on first MUX)
      │
      ├─ hexe pod daemon   (POD-0: pane aaaa...)
      │   └─ /bin/bash     (shell, PTY child)
      │       └─ vim       (fg process)
      │
      ├─ hexe pod daemon   (POD-1: pane bbbb...)
      │   └─ /bin/zsh      (shell, PTY child)
      │       └─ cargo     (fg process)
      │
      └─ hexe pod daemon   (POD-2: pane cccc...)
          └─ /bin/bash     (shell, PTY child)
              └─ hexe shp  (SHP hook, short-lived)
```

---

## Environment variables

Set by SES when spawning each POD — inherited by the shell and SHP:

```
HEXE_POD_SOCKET = /tmp/hexe/pod-<pane-uuid>.sock
HEXE_PANE_UUID  = <pane-uuid>            (32 hex chars)
HEXE_POD_NAME   = <star-name>            (human-friendly name)
HEXE_SES_SOCKET = /tmp/hexe/ses.sock
HEXE_INSTANCE   = <instance-name>
```

`HEXE_POD_SOCKET` never changes across MUX detach/reattach. The pane UUID is stable for the lifetime of the shell process.

---

## Crash recovery

- **MUX crash**: PODs keep running, SES keeps running. Reattach with `hexe mux attach`.
- **SES crash**: PODs keep running. SES restarts and reads persisted state from disk. MUX reconnects.
- **POD crash**: pane shows a "Shell exited" popup. Other panes are unaffected.

---

## Design properties

1. **MUX is disposable.** Kill it, close the terminal, crash — PODs keep running. Shells don't notice. Reattach restores everything.

2. **POD is the source of truth.** All pane metadata (cwd, fg process, shell events) originates from POD. SES and MUX are caches.

3. **SES is a stateless router.** It forwards VT bytes without inspection. Control messages are stored only for session persistence.

4. **Two hops, not N.** MUX always has exactly 2 fds to SES regardless of pane count. No per-pane connections from MUX.

5. **Binary everywhere.** No JSON parsing, no string formatting on the hot path. Control messages are packed structs read/written with `@memcpy`.

6. **VT and control never share a wire.** VT data cannot block control messages and vice versa. Each has its own fd and buffer.

7. **Non-blocking control.** MUX CTL channel is `O_NONBLOCK`. Periodic metadata requests are fire-and-forget. Responses arrive asynchronously in the poll loop.
