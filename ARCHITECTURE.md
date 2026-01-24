# Hexe Architecture

## Components

| Component | Role | Lifetime | Socket |
|-----------|------|----------|--------|
| **MUX** | Terminal UI, renders panes, handles input | User session | None (client only) |
| **SES** | Session daemon, routes I/O, manages state | Persistent | `ses.sock` (server) |
| **POD** | Per-pane PTY worker, source of truth | Until shell exits | `pod-<UUID>.sock` (server) |
| **SHP** | Shell hooks, renders prompt | Per-command | Connects to `pod-<UUID>.sock` |

All sockets live under `${XDG_RUNTIME_DIR:-/tmp}/hexe/`.

---

## Design Principles

1. **All binary, no JSON.** Control messages use packed structs with a universal envelope. No parsing, no allocations for simple messages.
2. **Separate VT and control channels.** VT bytes (PTY I/O) never share a pipe with control structs. The VT fast-path has zero overhead beyond a minimal frame header.
3. **Dedicated channel per pair.** No two modules share a pipe. Every fd carries traffic between exactly one pair, for exactly one purpose.
4. **POD is source of truth.** POD owns the PTY, reads /proc, receives SHP events. All pane state originates from POD.
5. **SES is a router.** SES forwards VT bytes between POD and MUX using splice() (zero-copy). SES never inspects VT content.

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              TERMINAL                                    │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │ raw tty
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                               MUX                                        │
│                                                                          │
│  Pure renderer. No POD knowledge. Talks only to SES.                     │
│                                                                          │
│  2 outbound connections to ses.sock:                                     │
│    [CTL] ─── control channel (binary structs) ─────────────┐            │
│    [VT]  ─── data channel (pane I/O, muxed by pane_id) ────┐│            │
└─────────────────────────────────────────────────────────────││───────────┘
                                                              ││
                                                          [VT]││[CTL]
                                                              ││
                                                              ▼▼
┌─────────────────────────────────────────────────────────────────────────┐
│                               SES                                        │
│                                                                          │
│  Listener: ses.sock                                                      │
│                                                                          │
│  Accepts:                                                                │
│    • MUX control connection   (handshake 0x01)                           │
│    • MUX VT data connection   (handshake 0x02)                           │
│    • POD control uplinks      (handshake 0x03 + pane_uuid)               │
│                                                                          │
│  Initiates (one per POD):                                                │
│    • POD VT data connection   (handshake 0x01 on pod socket)             │
│                                                                          │
│  VT forwarding: splice() zero-copy, never touches bytes in userspace     │
│                                                                          │
│  Per-pane routing table:                                                 │
│    pane_id → POD data fd                                                 │
│                                                                          │
└────┬────────┬────────┬────────┬────────┬────────┬───────────────────────┘
     │        ▲        │        ▲        │        ▲
     │[VT]    │[CTL]   │[VT]    │[CTL]   │[VT]    │[CTL]
     │SES     │POD     │SES     │POD     │SES     │POD
     │init    │init    │init    │init    │init    │init
     ▼        │        ▼        │        ▼        │
┌─────────────┴──┐ ┌─────────────┴──┐ ┌─────────────┴──┐
│     POD-0      │ │     POD-1      │ │     POD-2      │
│                │ │                │ │                │
│ Listener:      │ │ Listener:      │ │ Listener:      │
│  pod-0.sock    │ │  pod-1.sock    │ │  pod-2.sock    │
│                │ │                │ │                │
│ Accepts:       │ │ Accepts:       │ │ Accepts:       │
│  • SES [VT]    │ │  • SES [VT]    │ │  • SES [VT]    │
│  • SHP [CTL]   │ │  • SHP [CTL]   │ │  • SHP [CTL]   │
│                │ │                │ │                │
│ Connects out:  │ │ Connects out:  │ │ Connects out:  │
│  • SES [CTL]   │ │  • SES [CTL]   │ │  • SES [CTL]   │
└───────┬────────┘ └───────┬────────┘ └───────┬────────┘
        │ PTY               │ PTY               │ PTY
        ▼                   ▼                   ▼
      SHELL               SHELL               SHELL
        │                   │                   │
        ▼                   ▼                   ▼
       SHP ──[CTL]──→ POD SHP ──[CTL]──→ POD SHP ──[CTL]──→ POD
```

---

## Connection Matrix

```
         ┌──────────┬───────────┬───────────┬──────────┐
         │   MUX    │    SES    │    POD    │    SHP   │
┌────────┼──────────┼───────────┼───────────┼──────────┤
│  MUX   │    -     │ 2 conns   │   NONE    │   NONE   │
│        │          │ out:      │           │          │
│        │          │  ①ctl     │           │          │
│        │          │  ②vt mux  │           │          │
├────────┼──────────┼───────────┼───────────┼──────────┤
│  SES   │ accepts  │     -     │ 1 conn    │   NONE   │
│        │ ①+②     │           │ out:      │          │
│        │          │           │  ③vt data │          │
│        │ accepts  │           │           │          │
│        │ ④ctl    │           │           │          │
├────────┼──────────┼───────────┼───────────┼──────────┤
│  POD   │  NONE    │ 1 conn    │     -     │ accepts  │
│        │          │ out:      │           │ ⑤ctl    │
│        │          │  ④ctl    │           │          │
│        │          │ accepts:  │           │          │
│        │          │  ③vt data │           │          │
├────────┼──────────┼───────────┼───────────┼──────────┤
│  SHP   │  NONE    │   NONE    │ 1 conn    │    -     │
│        │          │           │ out:      │          │
│        │          │           │  ⑤ctl    │          │
└────────┴──────────┴───────────┴───────────┴──────────┘
```

### 5 Channel Types

```
① MUX→SES ctl     Binary structs: create_pane, layout_sync, pane_meta delivery
② MUX↔SES vt      Muxed VT: [pane_id:u16][type:u8][len:u32][payload]
③ SES↔POD vt      Direct VT: [type:u8][len:u32][payload] — no pane_id, implicit
④ POD→SES ctl     Binary structs: cwd_changed, fg_changed, shell_event, exited
⑤ SHP→POD ctl     Binary structs: shell_event, prompt_req/resp
```

---

## Wire Formats

### Universal Control Envelope (channels ①④⑤)

All control channels use the same binary envelope:

```
┌──────────────────────────────────────────────────┐
│  [msg_type: u16] [payload_len: u32] [payload…]   │
│                                                   │
│  payload = packed struct, layout depends on        │
│            msg_type enum value                     │
└──────────────────────────────────────────────────┘
```

Zig definition:

```zig
const ControlHeader = extern struct {
    msg_type: MsgType,
    payload_len: u32,
};

const MsgType = enum(u16) {
    // ① MUX→SES control
    create_pane = 0x0001,
    destroy_pane = 0x0002,
    layout_sync = 0x0003,
    reattach = 0x0004,
    detach = 0x0005,
    pane_created = 0x0006,      // SES→MUX response
    session_state = 0x0007,     // SES→MUX response (reattach)

    // ④ POD→SES control
    cwd_changed = 0x0100,
    fg_changed = 0x0101,
    shell_event = 0x0102,
    title_changed = 0x0103,
    bell = 0x0104,
    exited = 0x0105,

    // ④ SES→POD control
    query_state = 0x0180,
    kill_pane = 0x0181,

    // ⑤ SHP→POD control
    shp_shell_event = 0x0200,
    shp_prompt_req = 0x0201,
    shp_prompt_resp = 0x0202,   // POD→SHP response
};
```

Example message structs:

```zig
const CwdChanged = extern struct {
    path_len: u16,
    // followed by path_len bytes of path
};

const FgChanged = extern struct {
    pid: u32,
    name_len: u16,
    // followed by name_len bytes of process name
};

const ShellEvent = extern struct {
    status: i32,
    duration_ms: u32,
    cmd_len: u16,
    // followed by cmd_len bytes of command string
};

const CreatePane = extern struct {
    shell_len: u16,
    cwd_len: u16,
    // followed by shell_len + cwd_len bytes
};

const PaneCreated = extern struct {
    pane_uuid: [16]u8,
    pane_id: u16,       // short id for VT mux channel
};

const Resize = extern struct {
    cols: u16,
    rows: u16,
};
```

### VT Data Channel ② (MUX↔SES, multiplexed)

```
┌──────────────────────────────────────────────────────────┐
│  [pane_id: u16] [frame_type: u8] [len: u32] [vt_bytes…]  │
│                                                           │
│  Total header: 7 bytes per frame                          │
│                                                           │
│  frame_type:                                              │
│    0x01 = output      (SES → MUX)  PTY output data        │
│    0x02 = input       (MUX → SES)  user keystrokes        │
│    0x03 = resize      (MUX → SES)  payload=[cols:u16][rows:u16] │
│    0x04 = backlog_end (SES → MUX)  len=0, signals done    │
└──────────────────────────────────────────────────────────┘
```

`pane_id` is a u16 assigned by SES when the pane is created (returned in
`PaneCreated` response). Not the full UUID — compact for per-frame overhead.
SES maintains the pane_id → POD fd routing table.

### VT Data Channel ③ (SES↔POD, dedicated per pod)

```
┌──────────────────────────────────────────────────┐
│  [frame_type: u8] [len: u32] [vt_bytes…]          │
│                                                   │
│  Total header: 5 bytes per frame                  │
│                                                   │
│  Same frame_types as channel ②.                   │
│  No pane_id needed — this IS the pane.            │
└──────────────────────────────────────────────────┘
```

---

## Handshake Protocol

Each listener socket accepts multiple connection types. The first byte sent
after connect identifies the channel type:

### ses.sock handshake

```
Connecting client sends first byte:

  0x01 = MUX control channel ①
         Next: MUX sends register message (binary struct)

  0x02 = MUX VT data channel ②
         Next: MUX sends session_id (for routing to correct session)

  0x03 = POD control uplink ④
         Next: POD sends [pane_uuid: 16B] to identify itself
         Then: bidirectional control messages flow
```

### pod-<UUID>.sock handshake

```
Connecting client sends first byte:

  0x01 = SES VT data channel ③
         Next: bidirectional VT frames flow immediately

  0x02 = SHP control channel ⑤
         Next: SHP sends shell_event or prompt_req messages
```

---

## VT Forwarding Through SES (splice)

SES routes VT bytes between MUX and PODs without copying data into userspace:

```
Output path (POD → MUX):

  POD writes [0x01][len][bytes] on channel ③ fd
       │
       │ splice() into kernel pipe buffer
       ▼
  SES prepends [pane_id] header, splices to MUX channel ② fd
       │
       ▼
  MUX reads [pane_id][0x01][len][bytes]


Input path (MUX → POD):

  MUX writes [pane_id][0x02][len][bytes] on channel ② fd
       │
       ▼
  SES reads pane_id, looks up POD fd in routing table
  SES strips pane_id, splices [0x02][len][bytes] to POD channel ③ fd
       │
       ▼
  POD reads [0x02][len][bytes], writes to PTY
```

Latency overhead: ~5μs per unix socket hop. Imperceptible — terminal rendering
takes milliseconds. The kernel splice avoids memcpy entirely for the VT payload.

---

## POD as Source of Truth

```
┌──────────────────────────────────────────────────────┐
│                     POD Process                       │
│                                                      │
│  OWNS:                                               │
│  ┌────────────────────────────────────────────────┐  │
│  │  PTY master fd                                 │  │
│  │  4MB output ring buffer (backlog)              │  │
│  │  Child process PID                             │  │
│  │  Current working directory (from /proc)        │  │
│  │  Foreground process name + PID (from /proc)    │  │
│  │  Shell integration state (from SHP):           │  │
│  │    - Last command                              │  │
│  │    - Exit status                               │  │
│  │    - Duration                                  │  │
│  │    - Job count                                 │  │
│  │  Terminal dimensions (cols x rows)             │  │
│  │  Alt-screen state                              │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
│  3 channels:                                         │
│  ┌────────────────────────────────────────────────┐  │
│  │  [VT]  channel ③ (from SES):                   │  │
│  │    IN:  input frames, resize frames            │  │
│  │    OUT: output frames, backlog replay          │  │
│  │    Wire: [type:u8][len:u32][bytes]             │  │
│  ├────────────────────────────────────────────────┤  │
│  │  [CTL] channel ④ (to SES):                     │  │
│  │    OUT: cwd_changed, fg_changed, shell_event,  │  │
│  │         title_changed, bell, exited            │  │
│  │    IN:  query_state, kill_pane                 │  │
│  │    Wire: [msg_type:u16][len:u32][struct]       │  │
│  ├────────────────────────────────────────────────┤  │
│  │  [CTL] channel ⑤ (from SHP):                   │  │
│  │    IN:  shp_shell_event, shp_prompt_req        │  │
│  │    OUT: shp_prompt_resp                        │  │
│  │    Wire: [msg_type:u16][len:u32][struct]       │  │
│  └────────────────────────────────────────────────┘  │
│                                                      │
└──────────────────────────────────────────────────────┘
```

---

## Single POD Detail View

```
                          MUX
                           │
               ┌───────────┴───────────┐
               │                       │
           [CTL ①]                [VT ②]
           binary structs         [pane_id:u16][type:u8][len:u32][bytes]
               │                       │
               ▼                       ▼
┌──────────────────────────────────────────────────────────┐
│                           SES                             │
│                                                           │
│  Routing table:                                           │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ pane_id=0 → POD-0 VT fd   │  POD-0 CTL fd          │ │
│  │ pane_id=1 → POD-1 VT fd   │  POD-1 CTL fd          │ │
│  │ pane_id=2 → POD-2 VT fd   │  POD-2 CTL fd          │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                           │
└──────────┬────────────────────────────┬──────────────────┘
           │                            │
       [VT ③]                       [CTL ④]
       SES initiates                POD initiates
       to pod-0.sock                to ses.sock
           │                            │
           │      ┌─────────────────────┘
           │      │
           ▼      │
┌─────────────────┴────────────────────────────┐
│                POD-0                          │
│                                               │
│  ┌────────────────────────┐                  │
│  │ Channel ③ [VT]:        │                  │
│  │   ← input, resize      │                  │
│  │   → output, backlog    │                  │
│  └────────────────────────┘                  │
│                                               │
│  ┌────────────────────────┐                  │
│  │ Channel ④ [CTL to SES]:│                  │
│  │   → cwd_changed        │                  │
│  │   → fg_changed         │                  │
│  │   → shell_event        │                  │
│  │   → exited             │                  │
│  │   ← query_state        │                  │
│  └────────────────────────┘                  │
│                                               │
│  ┌────────────────────────┐                  │
│  │ Channel ⑤ [CTL fr SHP]:│                  │
│  │   ← shp_shell_event    │                  │
│  │   ← shp_prompt_req     │                  │
│  │   → shp_prompt_resp    │                  │
│  └────────────────────────┘                  │
│                                               │
│  ┌──────────────┐                            │
│  │   PTY m/s    │                            │
│  └──────┬───────┘                            │
└─────────┼────────────────────────────────────┘
          │
          ▼
        SHELL ──exec──→ SHP ──connect──→ pod-0.sock (handshake 0x02)
                              channel ⑤
```

---

## Environment Variables

```
SES sets for each POD at spawn:

  HEXE_POD_SOCKET = /tmp/hexe/pod-<pane-uuid>.sock
  HEXE_PANE_UUID  = <pane-uuid>
  HEXE_POD_NAME   = <star-name>
  HEXE_SES_SOCKET = /tmp/hexe/ses.sock
  HEXE_INSTANCE   = <instance-name>

POD inherits all. Shell inherits all. SHP uses HEXE_POD_SOCKET.

Flow:
  SES spawns POD (sets env)
   → POD starts, connects ④ back to HEXE_SES_SOCKET
   → POD listens on HEXE_POD_SOCKET
   → SES connects ③ to HEXE_POD_SOCKET
   → POD starts shell (shell inherits env)
   → Shell execs SHP → SHP connects ⑤ to HEXE_POD_SOCKET

Key property: HEXE_POD_SOCKET never changes across MUX detach/reattach.
The pane UUID is stable for the lifetime of the shell process.
```

---

## Process Lifecycle

### Startup

```
User runs: hexe mux
            │
            ▼
    ┌───────────────┐
    │   MUX starts  │
    │               │
    │ 1. Init state │
    │ 2. Find SES   │
    └───────┬───────┘
            │
            │ ses.sock exists?
            │
     ┌──────┴──────┐
     │             │
  exists?       missing?
     │             │
     ▼             ▼
  connect     fork/exec
  to SES      "hexe-ses daemon"
     │             │
     │         SES daemonizes
     │         creates ses.sock
     │             │
     └──────┬──────┘
            │
            ▼
    ┌────────────────────────────┐
    │ Open channel ① (ctl)       │
    │   handshake 0x01           │
    │   send: register msg       │
    │                            │
    │ Open channel ② (vt data)   │
    │   handshake 0x02           │
    └───────────┬────────────────┘
                │
                ▼
    ┌───────────────────┐       ┌───────────────────────────┐
    │ create_pane       │──────▶│  SES spawns POD process   │
    │ on channel ①      │       │                           │
    └───────┬───────────┘       │  POD starts:              │
            │                   │  1. Listen pod-<UUID>.sock│
            │                   │  2. Connect ④ to ses.sock │
            │                   │     (handshake 0x03+uuid) │
            │                   │  3. Start shell           │
            │                   │                           │
            │                   │  SES connects ③:          │
            │                   │  1. Connect to pod socket │
            │                   │     (handshake 0x01)      │
            │                   │  2. VT path ready         │
            │                   └───────────┬───────────────┘
            │                               │
            │ PaneCreated response          │
            │ (pane_uuid + pane_id)         │
            ▼                               │
    ┌───────────────────┐                   │
    │ MUX receives      │                   │
    │ pane_id, stores   │                   │
    │ in routing table  │                   │
    │                   │                   │
    │ VT data flows     │◀──────────────────┘
    │ through channel ② │
    └───────────────────┘
```

### Detach (Terminal Close)

```
Terminal closes
     │
     ▼
┌───────────────┐
│ MUX receives  │
│ SIGHUP/EOF    │
└───────┬───────┘
        │
        ▼
┌───────────────────────────┐
│ MUX sends on channel ①:   │
│   detach msg + layout      │
│                           │
│ MUX closes channels ①②   │
│ MUX exits.                │
└───────────┬───────────────┘
            │
            ▼
┌───────────────────────────────────┐
│ SES:                              │
│                                   │
│ - Stores layout                   │
│ - Marks session "detached"        │
│ - Channels ③④ stay alive!        │
│ - PODs keep buffering output      │
│ - SHP keeps working (→ POD ⑤)    │
│                                   │
│ Nothing breaks. No socket issues. │
└───────────────────────────────────┘
```

### Reattach

```
User runs: hexe mux attach pikachu
     │
     ▼
┌────────────────────────────────────────────┐
│ New MUX opens channel ① to ses.sock        │
│ Sends: reattach msg (session name)         │
│                                            │
│ SES responds on ①:                         │
│   session_state msg:                       │
│     - layout (binary, full pane tree)      │
│     - pane list (uuid + pane_id pairs)     │
└────────────────────┬───────────────────────┘
                     │
                     ▼
┌────────────────────────────────────────────┐
│ MUX opens channel ② to ses.sock            │
│                                            │
│ SES triggers backlog replay:               │
│   For each POD:                            │
│     request backlog on channel ③            │
│     POD sends output frames                │
│     SES prepends pane_id, forwards on ②    │
│     SES sends backlog_end frame            │
│                                            │
│ Then: live VT forwarding resumes           │
│                                            │
│ POD doesn't know MUX changed.             │
│ POD doesn't care.                          │
│ Channels ③④ were never interrupted.       │
└────────────────────────────────────────────┘
```

---

## Comparison: Old vs New Architecture

```
┌─────────────────────────────────┬─────────────────────────────────────┐
│        OLD (phases 1+2)         │         NEW (phases 3+4)            │
├─────────────────────────────────┼─────────────────────────────────────┤
│                                 │                                     │
│  Protocol: JSON-lines (control) │  Protocol: binary structs (all)     │
│  + binary frames (VT)           │  + binary frames (VT)               │
│  Mixed on same connection       │  Separate channels per purpose      │
│                                 │                                     │
│  MUX connections: N+1           │  MUX connections: 2                 │
│  (1 SES + N PODs)               │  (1 ctl + 1 vt data to SES)        │
│                                 │                                     │
│  SHP connects to: POD ✓         │  SHP connects to: POD ✓             │
│                                 │                                     │
│  MUX ↔ POD: direct binary       │  MUX ↔ POD: none                    │
│  frames per pane                │  All routed through SES             │
│                                 │                                     │
│  MUX ↔ SES: JSON control        │  MUX ↔ SES: binary ctl + muxed VT   │
│                                 │                                     │
│  POD ↔ SES: JSON uplink         │  POD ↔ SES: binary ctl + direct VT   │
│                                 │                                     │
│  Pane identity: full UUID       │  Pane identity: u16 pane_id         │
│  per frame (16 bytes)           │  per frame (2 bytes)                │
│                                 │                                     │
│  VT + control on same wire      │  VT and control on separate wires   │
│                                 │                                     │
│  SES: dumb registry             │  SES: active router (splice)        │
│                                 │                                     │
│  Detach: close N+1 connections  │  Detach: close 2 connections         │
│  Reattach: reconnect N PODs     │  Reattach: open 2 to SES, done      │
│                                 │                                     │
└─────────────────────────────────┴─────────────────────────────────────┘
```

---

## Migration Path

Phases 1 and 2 are complete (SHP→POD direct, POD→SES uplink).

### Phase 3: Binary Protocol + Separate Channels + SES VT Routing

```
1. Define wire.zig module:
   - ControlHeader struct (msg_type + payload_len)
   - MsgType enum (all message types)
   - VT frame header structs
   - Per-message payload structs
   - Serialization: std.mem.asBytes / bytesToValue

2. Create Channel abstraction:
   - Owns one socket fd
   - Handles framing (read header, read payload)
   - Typed send/recv for control messages
   - Raw send/recv for VT frames

3. Implement handshake protocol:
   - ses.sock: first byte identifies client type
   - pod socket: first byte identifies client type
   - After handshake, channel is dedicated

4. SES becomes VT router:
   - After spawning POD, SES connects to pod socket (③)
   - SES maintains pane_id → POD fd table
   - MUX opens VT data channel (②) to ses.sock
   - SES splices VT frames between ② and ③
   - splice() for zero-copy forwarding

5. Convert MUX↔SES control to binary:
   - Replace JSON create_pane with binary CreatePane struct
   - Replace JSON sync_state with binary layout_sync
   - All responses become binary structs

6. Convert POD↔SES control to binary:
   - Replace JSON cwd_changed etc with binary structs
   - POD connects ④ to ses.sock (handshake 0x03)

7. Remove MUX→POD direct connections:
   - MUX no longer opens connections to pod sockets
   - MUX no longer handles backlog replay directly
   - All VT I/O goes through channel ②

   Risk: Medium. Core protocol change but additive.
   Can run old and new protocols in parallel during transition.
```

### Phase 4: MUX Simplification

```
1. MUX state reduction:
   - Remove per-pane socket management
   - Remove backlog replay logic
   - Remove reader.reset() hacks
   - MUX only stores: pane_id → local render state

2. Pane metadata comes from SES:
   - SES forwards POD's cwd_changed/fg_changed to MUX on channel ①
   - MUX never queries POD directly
   - MUX never parses VT stream for metadata

3. Layout ownership:
   - MUX still owns layout (tabs, splits, floats)
   - MUX syncs layout to SES on changes (binary struct)
   - On reattach, SES returns stored layout

4. Remove old protocol code:
   - Remove JSON serialization from MUX/SES
   - Remove MUX IPC server (no longer needed, SHP→POD)
   - Remove MUX→POD connection code

   Risk: High. Major refactor of MUX internals.
   But the architecture is much simpler after.
```

---

## Trade-offs

### Advantages

```
+ All binary: no JSON parsing, no allocations, type-safe wire format
+ Separate channels: VT fast-path never blocked by control traffic
+ splice(): VT bytes never copied into SES userspace
+ MUX is trivial: 2 fds, pure renderer
+ Detach/reattach: just close/open 2 connections
+ Multiple MUXes: SES can forward to multiple viewers
+ POD isolation: doesn't know/care about MUX lifecycle
+ Debuggable: each channel has one purpose, easy to trace
```

### Disadvantages

```
- Extra hop for VT (POD → SES → MUX adds ~5μs)
  Mitigation: splice() zero-copy, unix sockets are kernel-local

- SES is single point of failure for I/O
  Mitigation: PODs keep shells alive if SES dies
  Mitigation: SES is simple (route bytes, no parsing)

- Binary protocol harder to debug than JSON
  Mitigation: Add hex dump mode / debug logging
  Mitigation: Zig makes struct layout deterministic

- More fds in SES (2 per POD + 2 from MUX)
  Mitigation: epoll handles thousands of fds efficiently
  Mitigation: SES is a daemon, not latency-sensitive for fd management
```
