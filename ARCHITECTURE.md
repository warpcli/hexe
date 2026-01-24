# Hexe Architecture

## Overview

Hexe is a terminal multiplexer with four components communicating over Unix domain
sockets using a binary protocol. All control messages are packed structs with a
6-byte envelope. VT (terminal I/O) data flows on dedicated channels, never mixed
with control traffic.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                TERMINAL                                     │
│                         (user's terminal emulator)                          │
└───────────────────────────────────┬─────────────────────────────────────────┘
                                    │ raw tty (stdin/stdout)
                                    │
┌───────────────────────────────────┴─────────────────────────────────────────┐
│                                  MUX                                        │
│                                                                             │
│   Renderer + input handler. Manages tabs, splits, floats.                   │
│   Talks ONLY to SES. Never connects to POD directly.                        │
│                                                                             │
│   2 outbound connections to ses.sock:                                       │
│     Channel ① ── control (binary structs, non-blocking)                     │
│     Channel ② ── VT data (multiplexed by pane_id)                           │
└──────────────────┬──────────────────────┬───────────────────────────────────┘
                   │ ①                    │ ②
                   │ control              │ VT muxed
                   │                      │
┌──────────────────┴──────────────────────┴───────────────────────────────────┐
│                                  SES                                        │
│                                                                             │
│   Session daemon. Routes VT between MUX and PODs.                           │
│   Manages pane lifecycle, persistence, detach/reattach.                     │
│                                                                             │
│   Listens: ses.sock                                                         │
│   Routing table: pane_id (u16) ──→ POD VT fd                                │
│                                                                             │
└───┬─────────┬───────┬─────────┬───────┬─────────┬──────────────────────────┘
    │ ③       │ ④     │ ③       │ ④     │ ③       │ ④
    │ VT      │ CTL   │ VT      │ CTL   │ VT      │ CTL
    │(SES→POD)│(POD→S)│         │       │         │
    ▼         │       ▼         │       ▼         │
┌─────────────┴─┐ ┌─────────────┴─┐ ┌─────────────┴─┐
│    POD-0      │ │    POD-1      │ │    POD-2      │
│               │ │               │ │               │
│  PTY owner    │ │  PTY owner    │ │  PTY owner    │
│  Backlog buf  │ │  Backlog buf  │ │  Backlog buf  │
│  /proc reader │ │  /proc reader │ │  /proc reader │
│               │ │               │ │               │
│  pod-0.sock   │ │  pod-1.sock   │ │  pod-2.sock   │
└───────┬───────┘ └───────┬───────┘ └───────┬───────┘
        │ PTY              │ PTY              │ PTY
        ▼                  ▼                  ▼
      SHELL              SHELL              SHELL
        │                  │                  │
        └──→ SHP ──⑤──→ POD    (per-command, short-lived)
```

---

## Components

| Component | Role | Lifetime | Socket |
|-----------|------|----------|--------|
| **MUX** | Terminal UI, input, layout | User session | None (client only) |
| **SES** | Session daemon, VT router | Persistent daemon | `ses.sock` (server) |
| **POD** | Per-pane PTY, backlog, metadata | Until shell exits | `pod-<UUID>.sock` (server) |
| **SHP** | Shell hooks, prompt, command metadata | Per-command | Connects to POD |

All sockets live under `${XDG_RUNTIME_DIR:-/tmp}/hexe/`.

---

## The 5 Channels

```
┌────────┬────────────────────┬────────────────────────────────────────────────┐
│Channel │ Endpoints          │ Purpose                                        │
├────────┼────────────────────┼────────────────────────────────────────────────┤
│   ①    │ MUX → SES          │ Control: create/destroy panes, detach,         │
│        │                    │ reattach, sync state, popups, notifications    │
├────────┼────────────────────┼────────────────────────────────────────────────┤
│   ②    │ MUX ↔ SES          │ VT data: multiplexed by pane_id               │
│        │                    │ Input (MUX→SES), Output (SES→MUX)             │
├────────┼────────────────────┼────────────────────────────────────────────────┤
│   ③    │ SES ↔ POD          │ VT data: one fd per POD, no pane_id needed    │
│        │                    │ Raw PTY I/O + backlog replay                  │
├────────┼────────────────────┼────────────────────────────────────────────────┤
│   ④    │ POD → SES          │ Control: cwd/fg/title changes, shell events,  │
│        │                    │ process exit notifications                    │
├────────┼────────────────────┼────────────────────────────────────────────────┤
│   ⑤    │ SHP → POD          │ Control: shell command metadata, prompt        │
│        │                    │ request/response                              │
└────────┴────────────────────┴────────────────────────────────────────────────┘
```

---

## Connection Matrix

```
              ┌──────────┬──────────┬──────────┬──────────┐
              │   MUX    │   SES    │   POD    │   SHP    │
   ┌──────────┼──────────┼──────────┼──────────┼──────────┤
   │   MUX    │    -     │ 2 conns  │  NONE    │  NONE    │
   │          │          │  ① ctl   │          │          │
   │          │          │  ② vt    │          │          │
   ├──────────┼──────────┼──────────┼──────────┼──────────┤
   │   SES    │ accepts  │    -     │ 1 conn   │  NONE    │
   │          │  ① ②    │          │  ③ vt    │          │
   │          │          │          │ (per POD)│          │
   │          │ accepts  │          │          │          │
   │          │  ④ ctl   │          │          │          │
   ├──────────┼──────────┼──────────┼──────────┼──────────┤
   │   POD    │  NONE    │ 1 conn   │    -     │ accepts  │
   │          │          │  ④ ctl   │          │  ⑤ ctl   │
   │          │          │ accepts: │          │          │
   │          │          │  ③ vt    │          │          │
   ├──────────┼──────────┼──────────┼──────────┼──────────┤
   │   SHP    │  NONE    │  NONE    │ 1 conn   │    -     │
   │          │          │          │  ⑤ ctl   │          │
   └──────────┴──────────┴──────────┴──────────┴──────────┘

   Key: "N conns" = N socket connections
        "accepts" = listens and accepts connections
        Direction in matrix: row initiates to column
```

---

## Wire Formats

### Control Envelope (Channels ①④⑤)

Every control message on every channel uses the same 6-byte header:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
│         msg_type (u16)        │             payload_len (u32)         │
├───────────────────────────────┼───────────────────────────────────────┤
│                         payload bytes ...                              │
└───────────────────────────────────────────────────────────────────────┘

Total: 6 bytes header + payload_len bytes payload
```

```zig
const ControlHeader = extern struct {
    msg_type: u16 align(1),
    payload_len: u32 align(1),
};
```

### MUX VT Frame (Channel ②)

Multiplexed VT data between MUX and SES. The `pane_id` identifies which pane
the frame belongs to.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
│       pane_id (u16)       │type│           len (u32)                   │
├───────────────────────────┼────┼───────────────────────────────────────┤
│                         VT bytes ...                                   │
└────────────────────────────────────────────────────────────────────────┘

Total: 7 bytes header + len bytes payload

frame_type:
  0x01 = output       (SES→MUX)  PTY output
  0x02 = input        (MUX→SES)  keystrokes
  0x03 = resize       (MUX→SES)  payload = [cols:u16][rows:u16]
  0x04 = backlog_end  (SES→MUX)  len=0, signals replay complete
```

### POD VT Frame (Channel ③)

Direct VT between SES and a single POD. No `pane_id` needed — the fd IS the pane.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
├─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┼─┤
│type│               len (u32)                                           │
├────┼───────────────────────────────────────────────────────────────────┤
│                         VT bytes ...                                   │
└────────────────────────────────────────────────────────────────────────┘

Total: 5 bytes header + len bytes payload
Same frame_types as Channel ②.
```

---

## Message Types

All message types are identified by a `u16` value in the control header.

### Channel ① — MUX ↔ SES Control (0x01xx)

```
 MsgType             Value    Direction   Payload Struct
─────────────────────────────────────────────────────────────────
 register            0x0100   MUX→SES     Register + name bytes
 registered          0x0101   SES→MUX     (empty)
 create_pane         0x0102   MUX→SES     CreatePane + shell + cwd + sticky
 pane_created        0x0103   SES→MUX     PaneCreated + socket_path
 destroy_pane        0x0104   MUX→SES     PaneUuid
 detach              0x0105   MUX→SES     Detach + layout JSON
 reattach            0x0106   MUX→SES     Reattach + session prefix
 session_state       0x0107   SES→MUX     (layout data)
 layout_sync         0x0108   MUX→SES     (layout update)
 notify              0x0109   SES→MUX     Notify + message
 pop_confirm         0x010A   SES→MUX     PopConfirm + message
 pop_choose          0x010B   SES→MUX     PopChoose + title + items
 pop_response        0x010C   MUX→SES     PopResponse
 disconnect          0x010D   MUX→SES     Disconnect
 sync_state          0x010E   MUX→SES     SyncState + layout JSON
 orphan_pane         0x010F   MUX→SES     PaneUuid
 list_orphaned       0x0110   MUX→SES     (empty)
 adopt_pane          0x0111   MUX→SES     PaneUuid
 kill_pane           0x0112   MUX→SES     PaneUuid
 set_sticky          0x0113   MUX→SES     SetSticky + pwd
 find_sticky         0x0114   MUX→SES     FindSticky + pwd
 pane_info           0x0115   MUX→SES     PaneUuid
 update_pane_aux     0x0116   MUX→SES     UpdatePaneAux + fields
 update_pane_name    0x0117   MUX→SES     UpdatePaneName + name
 update_pane_shell   0x0118   MUX→SES     UpdatePaneShell + fields
 get_pane_cwd        0x0119   MUX→SES     GetPaneCwd
 list_sessions       0x011A   MUX→SES     (empty)
 ping                0x011B   MUX→SES     (empty)
 pong                0x011C   SES→MUX     (empty)
 ok                  0x011D   SES→MUX     (ack)
 error               0x011E   SES→MUX     (error response)
 pane_found          0x011F   SES→MUX     PaneCreated
 pane_not_found      0x0120   SES→MUX     (empty)
 orphaned_panes      0x0121   SES→MUX     (list)
 sessions_list       0x0122   SES→MUX     (list)
 session_reattached  0x0123   SES→MUX     SessionReattached + JSON + UUIDs
 session_detached    0x0124   SES→MUX     (empty)
 send_keys           0x0125   CLI→SES     SendKeys + data
 broadcast_notify    0x0126   CLI→SES     Notify + message
 targeted_notify     0x0127   CLI→SES     Notify + message
 status              0x0128   CLI→SES     (status query)
 focus_move          0x0129   CLI→SES     FocusMove
 exit_intent         0x012A   SES→MUX     ExitIntent
 exit_intent_result  0x012B   MUX→SES     ExitIntentResult
 float_request       0x012C   SES→MUX     FloatRequest + cmd + env
 float_created       0x012D   MUX→SES     FloatCreated
 float_result        0x012E   MUX→SES     FloatResult + output
 pane_exited         0x012F   SES→MUX     PaneExited
```

### Channel ④ — POD → SES Control (0x04xx)

```
 MsgType             Value    Direction   Payload Struct
─────────────────────────────────────────────────────────────────
 cwd_changed         0x0400   POD→SES     CwdChanged + path
 fg_changed          0x0401   POD→SES     FgChanged + process name
 shell_event         0x0402   POD→SES     ShellEvent + cmd + cwd
 title_changed       0x0403   POD→SES     TitleChanged + title
 bell                0x0404   POD→SES     PaneUuid
 exited              0x0405   POD→SES     Exited
 query_state         0x0406   SES→POD     (request metadata)
 pod_register        0x0407   POD→SES     (registration ack)
```

### Channel ⑤ — SHP ↔ POD Control (0x05xx)

```
 MsgType             Value    Direction   Payload Struct
─────────────────────────────────────────────────────────────────
 shp_shell_event     0x0500   SHP→POD     ShpShellEvent + cmd + cwd
 shp_prompt_req      0x0501   POD→SHP     (request prompt data)
 shp_prompt_resp     0x0502   SHP→POD     (prompt response)
```

---

## Handshake Protocol

Each socket accepts multiple channel types. The first byte after `connect()`
identifies the channel:

### ses.sock (SES listens)

```
Client sends first byte:

  0x01 ─→ MUX control channel ①
           Next: Register struct (session_id + keepalive + name)
           Then: bidirectional control messages

  0x02 ─→ MUX VT data channel ②
           Next: 32-byte session_id (hex, to pair with channel ①)
           Then: bidirectional MuxVtHeader frames

  0x03 ─→ POD control uplink ④
           Next: 16 binary bytes (UUID, decoded from 32 hex chars)
           Then: POD sends metadata, SES sends queries

  0x04 ─→ CLI tool connection
           Next: control message (send_keys, notify, focus_move, etc.)
           Then: response, close
```

### pod-\<UUID\>.sock (POD listens)

```
Client sends first byte:

  0x01 ─→ SES VT data channel ③
           Next: bidirectional VT frames immediately
           POD replays backlog, then streams live output

  0x02 ─→ SHP control channel ⑤
           Next: SHP sends shell_event or prompt_req
           Short-lived connection (per-command)
```

---

## VT Data Flow

### User Types a Key

```
 TERMINAL
    │ keystroke
    ▼
   MUX ──── stdin read
    │
    │ writeMuxVt(vt_fd, pane_id=3, type=INPUT, "a")
    │
    │ Wire on channel ②:
    │ ┌────────┬────┬───────┬───┐
    │ │pane=3  │0x02│ len=1 │ a │
    │ └────────┴────┴───────┴───┘
    ▼
   SES ──── reads MuxVtHeader, extracts pane_id=3
    │
    │ Looks up: pane_id_to_pod_vt[3] → pod_fd
    │ Writes raw byte "a" to pod_fd
    ▼
   POD ──── reads from vt_fd
    │
    │ Writes "a" to PTY master
    ▼
  SHELL ──── receives "a" on PTY slave
```

### Shell Produces Output

```
  SHELL ──── writes "hello\n" to PTY slave
    │
    ▼
   POD ──── reads "hello\n" from PTY master
    │
    │ Writes to vt_fd (connected to SES):
    │ ┌────┬──────────┬─────────┐
    │ │0x01│  len=6   │ hello\n │   (5-byte header, channel ③)
    │ └────┴──────────┴─────────┘
    ▼
   SES ──── reads from pod_vt_fd
    │
    │ Looks up: pod_vt_to_pane_id[pod_vt_fd] → pane_id=3
    │ Writes MuxVtHeader to mux_vt_fd:
    │ ┌────────┬────┬──────────┬─────────┐
    │ │pane=3  │0x01│  len=6   │ hello\n │   (7-byte header, channel ②)
    │ └────────┴────┴──────────┴─────────┘
    ▼
   MUX ──── reads MuxVtHeader from vt_fd
    │
    │ Finds pane by pane_id=3
    │ Feeds "hello\n" to pane.vt emulator
    │ Renders to terminal
    ▼
 TERMINAL
```

### Resize

```
 TERMINAL resize event (SIGWINCH)
    │
    ▼
   MUX ──── recalculates layout
    │
    │ For each pane, writes to channel ②:
    │ ┌────────┬────┬───────┬──────┬──────┐
    │ │pane=3  │0x03│ len=4 │cols  │rows  │
    │ └────────┴────┴───────┴──────┴──────┘
    ▼
   SES ──── reads MuxVtHeader, sees type=RESIZE
    │
    │ Writes to pod_vt_fd:
    │ ┌────┬───────┬──────┬──────┐
    │ │0x03│ len=4 │cols  │rows  │   (channel ③)
    │ └────┴───────┴──────┴──────┘
    ▼
   POD ──── reads resize frame
    │
    │ Calls ioctl(pty_master, TIOCSWINSZ, ...)
    ▼
  SHELL ──── receives SIGWINCH
```

---

## Control Flow Examples

### Pane Creation

```
   MUX                          SES                          POD
    │                            │                            │
    │ create_pane                │                            │
    │ {shell="/bin/bash",        │                            │
    │  cwd="/home/user"}         │                            │
    ├───────────────────────────→│                            │
    │                            │ fork + exec                │
    │                            │ "hexe pod daemon           │
    │                            │   --uuid <UUID>"           │
    │                            ├───────────────────────────→│
    │                            │                            │
    │                            │       stdout: {"pid":1234} │
    │                            │←───────────────────────────┤
    │                            │                            │
    │                            │ connect pod-<UUID>.sock    │
    │                            │ send handshake 0x01        │
    │                            ├───────────────────────────→│
    │                            │         accepts (channel ③)│
    │                            │←───────────────────────────┤
    │                            │                            │
    │                            │         connect ses.sock   │
    │                            │         send 0x03 + UUID   │
    │                            │←───────────────────────────┤
    │                            │         (channel ④ ready)  │
    │                            │                            │
    │       pane_created         │                            │
    │       {uuid, pane_id=3,    │                            │
    │        pid=1234}           │                            │
    │←───────────────────────────┤                            │
    │                            │                            │
    │ VT data flows via ②←→③    │                            │
```

### Detach and Reattach

```
   MUX-1                        SES                         PODs
    │                            │                            │
    │ Terminal closes            │                            │
    │                            │                            │
    │ detach                     │                            │
    │ {session_id, layout_json}  │                            │
    ├───────────────────────────→│                            │
    │                            │ Store layout               │
    │                            │ Mark panes "detached"      │
    │                            │                            │
    │ disconnect                 │                            │
    ├───────────────────────────→│                            │
    │                            │                            │
    X (MUX exits)                │                            │
                                 │                            │
    PODs keep running ──────────────────────────────────────→ │ (shells alive)
    SES keeps channels ③④ open ─┤                            │
                                 │                            │
                                 │                            │
   MUX-2 (new terminal)         │                            │
    │                            │                            │
    │ register (new session_id)  │                            │
    ├───────────────────────────→│                            │
    │                            │                            │
    │ reattach {prefix="pika"}   │                            │
    ├───────────────────────────→│                            │
    │                            │ Find matching session      │
    │                            │ Restore layout             │
    │                            │                            │
    │       session_reattached   │                            │
    │       {layout_json,        │                            │
    │        pane UUIDs,         │                            │
    │        pane_ids}           │                            │
    │←───────────────────────────┤                            │
    │                            │                            │
    │ Open channel ② (VT)       │                            │
    ├───────────────────────────→│                            │
    │                            │                            │
    │                            │ Reconnect ③ to each POD   │
    │                            ├───────────────────────────→│
    │                            │                            │
    │                            │    POD replays backlog     │
    │                            │←───────────────────────────┤
    │                            │                            │
    │  backlog frames            │                            │
    │  (pane_id, type=OUTPUT)    │                            │
    │←───────────────────────────┤                            │
    │                            │                            │
    │  backlog_end per pane      │                            │
    │←───────────────────────────┤                            │
    │                            │                            │
    │  Live data resumes         │                            │
```

### POD Metadata Updates (Fire-and-Forget)

```
   SHELL                POD                  SES                  MUX
    │                    │                    │                    │
    │ cd /home/user/src  │                    │                    │
    ├───────────────────→│                    │                    │
    │                    │                    │                    │
    │                    │ tick() reads       │                    │
    │                    │ /proc/<pid>/cwd    │                    │
    │                    │ detects change     │                    │
    │                    │                    │                    │
    │                    │ cwd_changed        │                    │
    │                    │ {uuid, cwd}        │                    │
    │                    ├───────────────────→│                    │
    │                    │     (channel ④)    │                    │
    │                    │                    │ Updates pane state │
    │                    │                    │                    │
    │                    │                    │ Forwards to MUX    │
    │                    │                    │ (get_pane_cwd resp)│
    │                    │                    ├───────────────────→│
    │                    │                    │     (channel ①)    │
    │                    │                    │                    │
    │                    │                    │                    │ Updates
    │                    │                    │                    │ status bar
```

### Shell Event (SHP → POD → SES → MUX)

```
   SHELL               SHP                POD                SES              MUX
    │                    │                  │                  │                │
    │ Command finishes   │                  │                  │                │
    │ (precmd hook)      │                  │                  │                │
    ├───────────────────→│                  │                  │                │
    │                    │                  │                  │                │
    │                    │ connect          │                  │                │
    │                    │ pod-UUID.sock    │                  │                │
    │                    │ send 0x02        │                  │                │
    │                    ├─────────────────→│                  │                │
    │                    │                  │                  │                │
    │                    │ shp_shell_event  │                  │                │
    │                    │ {phase=END,      │                  │                │
    │                    │  status=0,       │                  │                │
    │                    │  duration=1234,  │                  │                │
    │                    │  cmd="make"}     │                  │                │
    │                    ├─────────────────→│                  │                │
    │                    │   (channel ⑤)    │                  │                │
    │                    │                  │                  │                │
    │                    X (SHP exits)      │ Stores metadata  │                │
    │                    │                  │                  │                │
    │                    │                  │ shell_event      │                │
    │                    │                  │ (forwards to SES)│                │
    │                    │                  ├─────────────────→│                │
    │                    │                  │  (channel ④)     │                │
    │                    │                  │                  │                │
    │                    │                  │                  │ shell_event    │
    │                    │                  │                  │ (forward)      │
    │                    │                  │                  ├───────────────→│
    │                    │                  │                  │  (channel ①)   │
    │                    │                  │                  │                │
    │                    │                  │                  │                │ Status bar:
    │                    │                  │                  │                │ "make ✓ 1.2s"
```

---

## SES Routing Tables

SES maintains bidirectional lookup tables to route VT frames:

```
┌─────────────────────────────────────────────────────────────┐
│                     SES State                                │
│                                                             │
│  Clients (per MUX connection):                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ session_id    → Client {                              │  │
│  │                   mux_ctl_fd: fd_t,   (channel ①)     │  │
│  │                   mux_vt_fd:  fd_t,   (channel ②)     │  │
│  │                   pane_uuids: []uuid,                 │  │
│  │                   keepalive:  bool,                   │  │
│  │                   name:       []u8,                   │  │
│  │                 }                                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  Panes (per shell):                                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ uuid          → Pane {                                │  │
│  │                   pane_id:     u16,                    │  │
│  │                   pod_vt_fd:   fd_t,   (channel ③)     │  │
│  │                   pod_ctl_fd:  fd_t,   (channel ④)     │  │
│  │                   pod_pid:     pid_t,                  │  │
│  │                   state:       PaneState,              │  │
│  │                   session_id:  ?[32]u8,                │  │
│  │                 }                                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  VT Routing (fast path):                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ pane_id_to_pod_vt:  HashMap(u16, fd_t)                │  │
│  │ pod_vt_to_pane_id:  HashMap(fd_t, u16)                │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  Detached Sessions (for reattach):                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ session_id    → DetachedState {                       │  │
│  │                   layout_json: []u8,                   │  │
│  │                   pane_uuids:  []uuid,                │  │
│  │                   name:        []u8,                   │  │
│  │                 }                                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## POD Internals

```
┌──────────────────────────────────────────────────────────────┐
│                       POD Process                             │
│                                                              │
│  OWNS:                                                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  PTY master fd              (reads output, writes input)│ │
│  │  4MB ring buffer            (backlog for replay)        │ │
│  │  Child PID                  (the shell process)         │ │
│  │  Terminal dimensions        (cols x rows)               │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  MONITORS (from /proc):                                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  /proc/<pid>/cwd           → current working directory  │ │
│  │  /proc/<pid>/stat          → foreground process name    │ │
│  │  /proc/<pid>/task/*/children → foreground PID           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  RECEIVES (from SHP, channel ⑤):                             │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Last command text                                      │ │
│  │  Exit status                                            │ │
│  │  Command duration (ms)                                  │ │
│  │  Job count                                              │ │
│  │  Running flag                                           │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  SOCKET: pod-<UUID>.sock                                     │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Accepts:                                               │ │
│  │    0x01 → SES VT (channel ③):                           │ │
│  │           Replay backlog, then stream live output        │ │
│  │           Receive input/resize frames                   │ │
│  │    0x02 → SHP control (channel ⑤):                      │ │
│  │           Receive shell events, respond to prompt reqs  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  UPLINK: connects to ses.sock (channel ④)                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Sends metadata changes:                                │ │
│  │    cwd_changed    (when /proc/<pid>/cwd changes)        │ │
│  │    fg_changed     (when foreground process changes)     │ │
│  │    shell_event    (forwarded from SHP)                  │ │
│  │    exited         (when child process exits)            │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Tick loop (500ms):                                          │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  1. Read /proc/<pid>/cwd                                │ │
│  │  2. If changed → send cwd_changed on channel ④          │ │
│  │  3. Read /proc/<pid>/stat                               │ │
│  │  4. If changed → send fg_changed on channel ④           │ │
│  │  5. Check child alive (waitpid WNOHANG)                 │ │
│  │  6. If exited → send exited on channel ④, cleanup       │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

---

## Pane State Machine

```
                    create_pane
                        │
                        ▼
                   ┌─────────┐
                   │ATTACHED │◄──────────────────────────────────┐
                   └────┬────┘                                   │
                        │                                        │
           ┌────────────┼────────────┐                           │
           │            │            │                           │
    MUX disconnect   orphan_pane  MUX disconnect                 │
    (keepalive=true)              (sticky pane)                  │
           │            │            │                           │
           ▼            │            ▼                           │
      ┌─────────┐      │      ┌──────────┐                     │
      │DETACHED │      │      │  STICKY  │                     │
      └────┬────┘      │      └─────┬────┘                     │
           │            │            │                           │
    reattach by         │     find_sticky                       │
    session prefix      │     (pwd+key match)                   │
           │            │            │                           │
           ▼            ▼            │                           │
      ┌─────────┐                    │                           │
      │ORPHANED │                    │                           │
      └────┬────┘                    │                           │
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

## MUX Pane Backends

MUX panes have two possible backends:

```
┌─────────────────────────────────────────────────────────────┐
│  Pane                                                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Backend = union(enum) {                             │    │
│  │                                                      │    │
│  │    .local ─→ Pty (MUX owns PTY fd directly)          │    │
│  │              Used for: ad-hoc floats (yazi, fzf)     │    │
│  │              I/O: MUX reads/writes PTY master        │    │
│  │              No SES routing needed                   │    │
│  │              Dies with MUX (not persistent)          │    │
│  │                                                      │    │
│  │    .pod ──→ { pane_id: u16, vt_fd: fd_t }            │    │
│  │              Used for: tiled panes, persistent floats │    │
│  │              I/O: through channel ② (via SES)         │    │
│  │              Survives MUX detach/reattach            │    │
│  │              Shell runs in separate POD process      │    │
│  │                                                      │    │
│  │  }                                                   │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  Common fields:                                              │
│    uuid: [32]u8         (pane identity)                      │
│    vt: VtEmulator       (terminal state machine)             │
│    width, height: u16   (dimensions)                         │
│    focused: bool                                             │
│    floating: bool       (float vs split)                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Non-Blocking CTL Pattern

Channel ① (MUX→SES control) uses non-blocking I/O to prevent deadlocks:

```
Problem scenario (if blocking):

   MUX                              SES
    │                                │
    │ pane_info request (blocking)   │
    ├───────────────────────────────→│
    │                                │
    │ ... waiting for response ...   │ VT data for MUX (channel ②)
    │                                ├─── tries to write ──→ BLOCKS
    │ can't read VT (blocked on ①)  │     (MUX not reading ②)
    │                                │
    ╳ DEADLOCK                       ╳


Solution: fire-and-forget + async response handling

   MUX                              SES
    │                                │
    │ pane_info request              │
    │ (non-blocking write,           │
    │  don't wait for response)      │
    ├───────────────────────────────→│
    │                                │
    │ poll loop continues...         │
    │ reads VT data normally         │ VT data flows fine
    │←───────────────────────────────┤
    │                                │
    │ Eventually: CTL fd readable    │
    │ reads pane_info response       │
    │←───────────────────────────────┤
    │ processes async response       │
```

**Fire-and-forget messages** (no response expected):
- `sync_state`, `update_pane_name`, `update_pane_shell`
- `get_pane_cwd` (response arrives asynchronously)
- `pane_info` (response arrives asynchronously)

**Synchronous messages** (must read response, uses `readSyncResponse` which skips stale async responses):
- `create_pane` → `pane_created`
- `reattach` → `session_reattached`
- `adopt_pane` → `pane_found`
- `ping` → `pong`

---

## Environment Variables

```
Set by SES when spawning each POD:

  HEXE_POD_SOCKET = /tmp/hexe/pod-<pane-uuid>.sock
  HEXE_PANE_UUID  = <pane-uuid>            (32 hex chars)
  HEXE_POD_NAME   = <star-name>            (human-friendly name)
  HEXE_SES_SOCKET = /tmp/hexe/ses.sock
  HEXE_INSTANCE   = <instance-name>

POD inherits all. Shell inherits all. SHP uses HEXE_POD_SOCKET to connect.

Key property: HEXE_POD_SOCKET never changes across MUX detach/reattach.
The pane UUID is stable for the lifetime of the shell process.
```

---

## Process Tree

```
Terminal Emulator
 └─ hexe mux              (MUX process, user-facing)
      │
      └─ (connects to ses.sock)
              │
     hexe-ses daemon       (SES daemon, long-lived, started on first MUX)
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

## Design Properties

1. **MUX is disposable.** Kill it, close the terminal, crash — PODs keep running.
   Shells don't notice. Reattach restores everything.

2. **POD is the source of truth.** All pane metadata (cwd, fg process, shell events)
   originates from POD. SES and MUX are caches.

3. **SES is a stateless router.** It forwards VT bytes without inspection. Control
   messages are stored only for session persistence.

4. **Two hops, not N.** MUX always has exactly 2 fds to SES regardless of pane count.
   No per-pane connections from MUX.

5. **Binary everywhere.** No JSON parsing, no string formatting on the hot path.
   Control messages are packed structs read/written with `@memcpy`.

6. **VT and control never share a wire.** VT data cannot block control messages
   and vice versa. Each has its own fd and buffer.

7. **Non-blocking control.** MUX CTL channel is O_NONBLOCK. Periodic metadata
   requests are fire-and-forget. Responses arrive asynchronously in the poll loop.
