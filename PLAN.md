# PLAN: Make the terminal frontend one host adapter

## Goal

Hexe should support multiple frontends without making the terminal UI the source
of truth for everything.

The terminal frontend should become **one host adapter**:

```text
TerminalHost  -> FrontendCore -> FrontendRuntime -> SES -> POD
WebHost       -> FrontendCore -> FrontendRuntime -> SES -> POD
SyslinkHost   -> FrontendCore -> FrontendRuntime -> SES -> POD
```

The important boundary:

- **FrontendCore** owns session state, pane/float/tab actions, SES CTL/VT handling,
  attach/detach/reattach logic, and frontend-neutral events.
- **Host adapters** own input/output details for a specific surface:
  - terminal raw mode, terminal input, vaxis rendering;
  - web websocket/browser rendering;
  - syslink/ssh-like remote transport and terminal bridging.

## Why this matters

Right now `src/frontends/terminal/*` is both:

1. the terminal implementation; and
2. the implicit frontend architecture.

That makes every new frontend risky because web/syslink would either:

- duplicate terminal-specific logic; or
- pretend to be a terminal even when the host model is different.

The long-term target is that terminal, web, and syslink all reuse the same
session/action/protocol core.

## Progress

- [x] Added the initial `src/frontends/core/` boundary documentation.
- [x] Added frontend-neutral `HostEvent` / `HostCommand` / stop-request types.
- [x] Moved the first low-risk behavior behind the boundary: runtime stop
  reasons now map through `frontend_core.stopRequestFromRuntime(...)`.
- [x] Moved the first VT protocol classification helper behind the boundary:
  terminal now consumes `frontend_core.vtFrameEventFromHeader(...)` instead of
  hard-coding POD frame meaning in the VT read loop.
- [x] Moved VT frame read/drain mechanics behind the boundary:
  terminal now calls `frontend_core.readMuxVtFrame(...)` and only applies the
  returned semantic event to terminal pane state.
- [x] Moved the first CTL protocol classification helper behind the boundary:
  terminal IPC dispatch now consumes `frontend_core.ctlEventKindFromMsgType(...)`
  instead of owning the generic SES message category table.
- [x] Moved CTL header read/classification mechanics behind the boundary:
  terminal IPC now calls `frontend_core.readCtlFrameHeader(...)` and dispatches
  typed payload handlers from the returned semantic event.
- [x] Added the first frontend-neutral action normalization helper:
  terminal keybinding dispatch now shares direction/action semantic normalization
  from `frontend_core.actions` instead of each host needing its own mapping.
- [x] Added the initial `TerminalHost` adapter entrypoint:
  `main.zig` now calls `src/frontends/terminal/host.zig` instead of directly
  treating `loop_core.runMainLoop(...)` as the frontend boundary.
- [x] Moved terminal lifecycle ownership into `TerminalHost`:
  raw mode, alternate-screen setup, capability-query startup, and cleanup now
  live in `src/frontends/terminal/host.zig` instead of `loop_core.zig`.
- [x] Moved terminal resize polling and render execution behind host hooks:
  `loop_core` now asks `TerminalHost` to poll resize and render instead of
  importing terminal/renderer implementation modules directly.
- [x] Moved terminal render scheduling behind host hooks:
  the 60fps render throttle now lives in `TerminalHost` instead of `loop_core`.
- [x] Moved terminal capability-query finalization behind host hooks:
  query timeout/final feature enablement is now terminal-host lifecycle logic.
- [x] Moved terminal input dispatch/disconnect semantics behind host hooks:
  stdin watcher callbacks now delegate byte input and lost-connection handling
  to `TerminalHost` instead of importing terminal input parsing directly.
- [x] Moved terminal stdin fd/read mechanics behind host hooks:
  `TerminalHost` now supplies the input fd and read function used by the stdin
  watcher.
- [x] Moved stop-request presentation behind host hooks:
  `loop_core` still consumes runtime stop reasons, but `TerminalHost` owns how
  session-stolen/user-facing stop messages are presented.
- [x] Moved xev loop/timer lifecycle into `TerminalHost`:
  `host.zig` now detects/initializes/deinitializes the xev loop and timer, while
  `loop_core` receives them as host-owned runtime resources.
- [x] Moved xev watcher/buffer storage ownership into `TerminalHost`:
  `host.zig` now creates `loop_watchers.LoopResources` and passes it into the
  loop, so watcher state is host-owned.
- [x] Moved terminal xev watcher callback implementations out of `loop_core`:
  stdin, SES CTL, and SES VT watcher plumbing now lives in
  `src/frontends/terminal/loop_watchers.zig`, with terminal-specific host
  operations supplied through `loop_host_hooks.zig`.
- [x] Split terminal runtime/deferred event application out of `loop_core`:
  `src/frontends/terminal/runtime_events.zig` now owns pending pane-exit/CWD/
  pane-info/session-snapshot application plus runtime stop-request bridging.
- [x] Split dead float cleanup and shell-death respawn handling out of
  `loop_core`: `src/frontends/terminal/dead_panes.zig` now owns that lifecycle
  slice, leaving the main loop to call it.
- [x] Split dead split cleanup out of `loop_core`: `dead_panes.zig` now owns
  split death collection/removal, background-exit notification, tab-close-on-
  last-pane behavior, and last-pane shell-death confirmation.
- [x] Split terminal periodic UI updates out of `loop_core`:
  `src/frontends/terminal/loop_updates.zig` now owns mouse-selection auto-scroll,
  status refresh cadence, overlay/notification/popup expiry, popup response
  timeout handling, and keybinding timers.
- [x] Added `frontend_core.FrontendHostSession`, a frontend-neutral
  runtime/session wrapper that owns `SessionView` refresh, pending runtime event
  application, and generic host close/connection-loss stop semantics for
  non-terminal hosts.
- [x] Added frontend-core unit coverage to `make test`.
  - [x] Extract frontend-neutral actions from terminal action files.
  - [x] Terminal keybinding dispatch now consumes
    `frontend_core.actionRequestFromBindAction(...)`, so raw config bind-action
    semantics are normalized before the terminal-specific implementation runs.
  - [x] Moved the first view-state mutations behind the shared model:
    `SessionView` now owns active-tab, active-float, and focused-pane update
    helpers, and terminal `State` mirrors tab/float focus changes through those
    helpers instead of directly owning that projection alone.
  - [x] Added the first shared action application helper:
    `frontend_core.applyViewAction(...)` now applies pure tab navigation
    (`tab_next`/`tab_prev`) to `SessionView` with unit coverage, while
    explicitly reporting host/SES-backed actions as unsupported for now.
  - [x] Terminal tab navigation now routes through that shared action helper
    when the `SessionView` mirror is available, then applies the terminal-only
    focus/renderer side effects around the shared target tab.
  - [x] Focus mutations now mirror through the shared view model first:
    `SessionView.applyFocusedPane(...)` and
    `SessionView.applyTabFocusedPane(...)` validate focused-pane identity and
    keep tab-local focused split state in the frontend-neutral projection while
    terminal `State` keeps the rendering/cache side effects.
  - [x] Tab removal now has a shared model mutation:
    `SessionView.applyRemoveTab(...)` removes split panes owned by the tab,
    removes tab-bound float panes, reindexes pane/float parent-tab references,
    repairs active focus, and terminal close-tab mirrors through the shared
    `tab_close` action after local presentation cleanup.
  - [x] Tab/split/pane structural mutations now have shared model helpers:
    `SessionView.applyAddTab(...)`, `applySplitPane(...)`, and
    `applyRemovePane(...)` keep the frontend-neutral projection in sync for
    terminal tab creation, split creation, split close, and float close without
    waiting for a later full session snapshot.
  - [x] Float sync now has a shared model mutation:
    `SessionView.applySyncFloat(...)` updates/creates float pane metadata,
    canonical float visibility/geometry/sticky/per-CWD fields, active-float
    state, and focus from the same path terminal uses after SES float sync.
  - [x] Pane UUID replacement now has a shared model mutation:
    `SessionView.applyReplacePane(...)` updates pane/float UUID references and
    repairs focused/active references for adopt/disown/respawn-style pane
    replacement flows.
  - [x] Shared tab view state now carries the frontend-neutral split layout
    tree cloned from SES snapshots. Tab/split/pane add/remove/replace
    mutations update that tree, and `SessionView.applySplitRatio(...)` mirrors
    resize ratio changes for future non-terminal renderers.
  - [x] Split-resize action state now has a shared model handler:
    `SessionView.applyResizeFocusedSplit(...)` finds the resize target in the
    frontend-neutral layout tree, applies clamped ratio changes, and returns
    the canonical anchor/ratio payload terminal sends to SES.
  - [x] Float geometry updates now have a shared model mutation:
    `SessionView.applyFloatGeometry(...)` updates the frontend-neutral float
    geometry fields, and terminal float nudging now updates shared state plus
    SES/runtime metadata instead of being local UI-only.
  - [x] Added a contextual shared action handler:
    `frontend_core.applyViewActionWithContext(...)` applies tab navigation,
    tab create/close, split create, pane close/removal, focus move, split
    resize, and float nudge/geometry mutations through one frontend-core action
    entrypoint while returning structured outcomes such as split-ratio sync
    payloads.
  - [x] Terminal tab-add and split-add mirroring now happens in the shared
    sync wrappers (`syncSessionTabAddedChecked(...)` and
    `syncSessionSplitPaneChecked(...)`) instead of individual keybinding
    callsites, so layout/config/reattach-created tabs and splits update the
    shared projection too.
  - [x] Moved shared-view state mutation implementations behind
    frontend-core action handlers once the shared view/session model was
    extracted; terminal no longer calls `SessionView.apply*` directly.
- [x] Extract SES CTL/VT event processing from the terminal loop.
  - [x] SES CTL header draining/classification now runs through
    `frontend_core.drainCtlFrameHeaders(...)`; terminal only dispatches typed
    payload handlers.
  - [x] SES VT frame draining/classification now runs through
    `frontend_core.drainMuxVtFrames(...)`; terminal only applies output/backlog
    events to pane screen state.
  - [x] Added initial `frontend_core.SessionView`, a render-free view projection
    from canonical SES snapshots that web/syslink can consume without terminal
    state types.
  - [x] Extended `SessionView` with frontend-neutral pane runtime metadata
    (pane name, shell command/CWD/status/jobs, foreground process name/pid) and
    a `fromRuntime(...)` bridge so hosts can build shared state from the current
    runtime projection.
  - [x] Added shared application helpers for async typed runtime events:
    `SessionView.applyPendingRuntimeEvents(...)` now drains pane exits, CWD
    responses, and pane-info responses into the frontend-neutral model.
  - [x] Added `frontend_core.ses_events` as the host-facing shared SES/runtime
    event application module, and exposed it through WebHost/SyslinkHost so
    non-terminal adapters can apply queued runtime events before rendering.
  - [x] Moved first typed CTL payload parsing helpers into frontend core:
    `frontend_core.ctl_payloads` now reads/drains shared `get_pane_cwd` and
    `pane_info` payload shapes, so terminal no longer owns that wire parsing.
  - [x] Moved shell lifecycle CTL payload parsing into frontend core:
    `frontend_core.ctl_payloads` now reads/drains shared `shell_event` payloads,
    so terminal owns application/presentation but not the wire parsing.
  - [x] Moved `send_keys` and `focus_move` CTL payload parsing into frontend
    core, including shared direction normalization for focus-move payloads.
  - [x] Moved `pop_confirm` CTL payload parsing into frontend core; terminal
    still resolves popup targets and presentation options.
  - [x] Moved `pop_choose` CTL payload parsing into frontend core; terminal
    still resolves popup targets and presentation options.
  - [x] Moved `notify`, `targeted_notify`, and `exit_intent` CTL payload
    parsing into frontend core; terminal still owns notification routing and
    exit-confirmation policy.
  - [x] Moved shared pane-UUID CTL payload parsing into frontend core and
    switched terminal `pane_exited` handling to use it.
  - [x] Move typed payload application into a shared frontend view/session model
    instead of terminal `State`.
    - [x] Terminal now maintains a mirrored `frontend_core.SessionView`
      alongside the legacy terminal `State`, refreshing it from runtime
      snapshots and updating it for typed CWD, pane-info, shell-event, and
      pane-exit events.
    - [x] Added shared `frontend_core.ses_events` application helpers for
      pane-CWD, pane-info, shell-event, and pane-exited CTL payloads, so hosts
      can apply typed SES events to `SessionView` without depending on terminal
      state mutation code.
    - [x] Added shared focus application helpers and terminal mirroring for
      global focused pane plus per-tab split focus, reducing another terminal-
      only state mutation path.
    - [x] Added shared tab-removal application and terminal close-tab mirroring,
      so non-terminal hosts can test the canonical view projection for removed
      tabs without depending on terminal `State`.
    - [x] Added shared tab-add, split-add, and pane-removal application paths,
      including unit coverage for parent-tab reindexing, focused-pane repair,
      and float metadata cleanup in `SessionView`.
    - [x] Added shared float-sync application and terminal mirroring for
      visibility, tab visibility, geometry, sticky/per-CWD metadata, active
      float, and focus state.
    - [x] Added shared pane-UUID replacement application and centralized tab/
      split add mirroring inside terminal session-sync wrappers, reducing
      action-specific duplicate state mutation paths.
    - [x] Added shared split-layout tree projection and split-ratio mirroring,
      so web/syslink can inspect canonical layout structure without terminal
      `Layout` or vaxis state.
    - [x] Added shared focused-split resize application and terminal routing for
      split-resize keybindings, moving another view mutation behind
      `SessionView` instead of terminal layout state alone.
    - [x] Added shared float-geometry application and routed float nudge through
      shared/session metadata sync, so nudge is no longer just terminal UI
      state.
    - [x] Added contextual shared action application for split resize and float
      nudge, so these keybindings no longer call `SessionView` mutations
      directly from terminal-only action code.
    - [x] Routed directional focus move through the contextual shared action
      handler with an explicit target pane UUID, so focus-move keybindings now
      update the shared model before terminal presentation/session side effects.
    - [x] Routed pane close/removal through the contextual shared action handler
      with explicit removed/next-focus UUIDs, reducing another direct terminal
      `SessionView` mutation path.
    - [x] Routed tab creation and split creation through the contextual shared
      action handler with explicit UUID/name/split context, reducing direct
      terminal calls to `SessionView.applyAddTab(...)` and
      `SessionView.applySplitPane(...)`.
    - [x] Routed active tab selection, active float selection/clearing, focus
      setting/clearing, and per-tab split focus through contextual shared
      actions, removing the remaining direct terminal calls to
      `SessionView.applyActiveTab(...)`, `applyActiveFloat(...)`,
      `applyFocusedPane(...)`, and `applyTabFocusedPane(...)`.
    - [x] Routed non-active tab removal through a contextual shared
      `tab_remove` action, so terminal no longer calls any `SessionView.apply*`
      mutation directly from terminal state files.
    - [x] Routed generic float geometry mirroring through the contextual shared
      action handler, so both float nudge and non-keybinding geometry sync use
      the same frontend-core mutation path.
    - [x] Moved remaining shared-view terminal mutations to operate through the
      shared model/action layer first; terminal `State` still owns
      presentation/cache details, but no longer directly mutates the canonical
      frontend `SessionView` projection.
- [x] Add request IDs and stronger per-client VT output queues.
  - [x] Added initial per-client MUX VT output queues in SES for POD→MUX frames.
  - [x] Switched queue draining to non-blocking partial writes so a slow mux
    cannot stall the SES periodic path for the full VT I/O timeout.
  - [x] Add CTL request IDs.
    - [x] Added `request_id` to the CTL header, bumped the wire protocol to v3,
      and added request-id write helpers/tests.
    - [x] Frontend client CTL requests now allocate non-zero request ids.
    - [x] SES direct replies echo the request id only when replying to the
      request fd; async/forwarded events keep request id `0`.
    - [x] Sync readers now require the expected response request id for command
      acks and direct sync responses, while still queueing async CWD/pane/session
      events.
    - [x] Add a generic pending-response store for truly concurrent sync
      requests if hosts start issuing overlapping CTL requests from multiple
      tasks.
      - [x] Added in-memory pending CTL response storage keyed by request id,
        and taught command-ack readers to queue/replay out-of-order `ok`/`error`
        responses instead of rejecting them.
      - [x] Taught the synchronous pane-CWD reader to queue and replay
        out-of-order payload-bearing `get_pane_cwd` responses by request id.
      - [x] Taught synchronous pane-info readers to preserve an owned trailing
        payload buffer when replaying queued `pane_info` responses by request id.
      - [x] Extended non-ack direct response readers with a shared
        `ControlResponseRead` wrapper, so out-of-order direct response payloads
        are queued by request id and later replayed from owned memory instead
        of forcing every caller to read payload bytes directly from the CTL fd.
  - [x] Audited VT write-ready draining against the vendored libxev stream
    API: current `PollEvent` exposes read readiness only for the selected
    stream abstraction, so Hexe keeps bounded non-blocking periodic draining
    plus coalescing until a writable poll event is available.
  - [x] Added initial coalescing/drop policy for low-value `backlog_end` frames.
  - [x] Added broader coalescing/drop policy for low-value POD→MUX frames:
    queued unwritten `backlog_end` and `password_mode` frames now coalesce by
    pane, and both are dropped instead of tearing down the mux if a slow-client
    VT queue is already full.
  - [x] Added initial structured disconnect reasons:
    frontend-neutral host disconnect events now carry a `DisconnectReason`, and
    the SES `disconnect` wire payload carries a compact reason byte for
    graceful frontend shutdown logging/policy.
  - [x] Added first capability negotiation payload:
    frontend registration now carries wire capability flags, SES stores them on
    the client record, and `HostCapabilities` can round-trip to/from the wire
    flag set with unit coverage.
- [x] Add concrete WebHost/SyslinkHost adapters.
  - [x] Added initial `src/frontends/web/host.zig` adapter that maps browser
    events into frontend-neutral `HostEvent`s without terminal dependencies.
  - [x] Added initial `src/frontends/syslink/host.zig` adapter that maps
    ssh-like remote terminal/transport events into frontend-neutral
    `HostEvent`s without pretending to be local IPC.
  - [x] Added `src/frontends/web/mod.zig` and
    `src/frontends/syslink/mod.zig` module entrypoints so future runnable
    commands import the adapter packages instead of individual host files.
  - [x] WebHost/SyslinkHost can now apply canonical SES session JSON into the
    shared `frontend_core.SessionView`, giving both adapters terminal-free
    snapshot state for future rendering/reconnect flows.
  - [x] Added coarse `HostCapabilities` defaults for terminal/web/syslink-style
    hosts; TerminalHost/WebHost/SyslinkHost now expose those capabilities, with
    unit coverage for the new non-terminal adapters.
  - [x] Wired initial runnable CLI diagnostics for the non-terminal adapters:
    `hexe web inspect-snapshot <snapshot.json>` and
    `hexe syslink inspect-snapshot <snapshot.json>` load canonical session JSON
    through WebHost/SyslinkHost and print the shared view model without terminal
    state types.
  - [x] Wired first live non-terminal frontend entrypoints:
    `hexe web probe` and `hexe syslink probe` instantiate their host adapters,
    connect a non-terminal `FrontendRuntime` to SES, and print host
    capabilities/session identity without importing terminal state types.
  - [x] Routed the probe entrypoints through `frontend_core.FrontendHostSession`
    so web/syslink no longer grow their own attach/view/stop ownership while
    the real render transports are still being designed.
  - [x] Defined the first minimal frontend-neutral line host protocol
    (`tick`, `render`, `resize`, `close`, `disconnect`, `exit`) in
    `frontend_core.host_protocol`.
  - [x] Added `hexe web serve` and `hexe syslink serve` serving loops that stay
    attached through `FrontendHostSession`, accept host-protocol events on
    stdin, and emit shared-view render summaries without importing terminal
    state types.

## Current code map

### Frontend runtime / protocol client

- `src/core/frontend_runtime.zig`
  - session projection facade;
  - attach/detach/reattach API;
  - action-facing wrapper around `SesClient`.

- `src/core/frontend_client.zig`
  - low-level SES client;
  - CTL channel;
  - VT channel;
  - local IPC, preconnected, and liblink transport variants.

- `src/core/frontend_liblink_transport.zig`
  - current syslink-like prototype;
  - opens remote `hexe session pipe` sessions and bridges bytes.

- `src/core/wire.zig`
  - binary CTL and VT protocol;
  - `FrontendKind` already includes `terminal`, `web`, `desktop`.

### Terminal frontend

- `src/frontends/terminal/main.zig`
  - process entrypoint;
  - signals;
  - attach/list handling;
  - terminal startup and config application.

- `src/frontends/terminal/loop_core.zig`
  - main loop cadence;
  - runtime stop/deferred event application;
  - timer-driven pane sync/heartbeat;
  - dead-pane cleanup;
  - overlay/popup/key-timer updates;
  - host hook calls for resize/render/capability handling.

- `src/frontends/terminal/loop_watchers.zig`
  - host-owned stdin/SES CTL/SES VT xev watcher storage;
  - watcher callback implementations;
  - VT frame application to terminal pane buffers;
  - CTL event dispatch into terminal IPC handlers.

- `src/frontends/terminal/loop_host_hooks.zig`
  - host hook interface used by `loop_core` and `loop_watchers`.

- `src/frontends/terminal/runtime_events.zig`
  - terminal projection of queued runtime side-channel events;
  - runtime stop reason to host stop-request bridging.

- `src/frontends/terminal/dead_panes.zig`
  - dead float cleanup;
  - active-float index repair after dead-float cleanup;
  - dead split cleanup;
  - last-pane shell-death confirmation path;
  - deferred shell-death respawn handling.

- `src/frontends/terminal/loop_updates.zig`
  - mouse selection auto-scroll;
  - status refresh cadence;
  - overlay/notification/popup/key-timer maintenance.

- `src/frontends/terminal/loop_input*.zig`
  - terminal byte input;
  - key parsing;
  - mouse/paste/input dispatch.

- `src/frontends/terminal/loop_actions*.zig`
  - pane/tab/float/session actions.

- `src/frontends/terminal/state*.zig`
  - frontend UI/session state;
  - attach/reattach restore;
  - snapshot application;
  - float/tab metadata.

- `src/frontends/terminal/render*.zig`
  - vaxis/terminal rendering.

### Session daemon / POD

- `src/modules/session/*`
  - canonical pane/session state;
  - attach/detach/reattach;
  - sticky panes;
  - CTL/VT routing.

- `src/modules/pod/*`
  - PTY child;
  - output backlog;
  - password-mode privacy;
  - shell cwd/fg-process uplink.

## Non-goals

- Do not build the full web UI in this refactor.
- Do not replace the terminal renderer yet.
- Do not rewrite SES/POD wholesale.
- Do not add another huge behavior change to CWD sticky floats while doing this.
- Do not make terminal behavior worse to make abstractions prettier.

## Target architecture

### 1. FrontendCore

Create a frontend-neutral core under something like:

```text
src/frontends/core/
```

or, if keeping shared logic under `src/core` is preferred:

```text
src/core/frontend_core.zig
```

Responsibilities:

- own `FrontendRuntime`;
- own frontend-neutral session/view model;
- apply session snapshots;
- process SES CTL events;
- process SES VT frames into pane screen state;
- expose actions:
  - quit/detach;
  - tab new/close/switch;
  - pane split/close/adopt/disown;
  - float toggle/move/resize;
  - focus movement;
  - send input to focused pane;
  - resize pane/backend sizes;
- produce frontend-neutral events for hosts:
  - needs render;
  - notification;
  - session stolen;
  - pane exited;
  - attach/reattach completed/failed;
  - cursor/focus changed.

FrontendCore should **not**:

- enter raw mode;
- print to stdout/stderr;
- know terminal escape sequences;
- depend on vaxis;
- parse terminal-specific keyboard protocols directly;
- own browser websocket details;
- own liblink/syslink connection setup details.

### 2. HostAdapter interface

Define a small host contract. Shape does not need to be exactly this, but the
boundary should be this clear:

```zig
pub const HostEvent = union(enum) {
    input_bytes: []const u8,
    key: KeyEvent,
    mouse: MouseEvent,
    paste: []const u8,
    resize: struct { cols: u16, rows: u16 },
    tick,
    close_requested,
    connection_lost,
};

pub const HostCommand = union(enum) {
    render,
    notify: []const u8,
    set_cursor,
    set_clipboard: []const u8,
    exit,
};
```

Terminal host maps stdin/TTY events into `HostEvent`.

Web host maps websocket/browser events into `HostEvent`.

Syslink host can either:

- expose a remote terminal host; or
- expose a transport host that carries CTL/VT streams to a local UI.

### 3. TerminalHost

Terminal-specific code should live in a terminal host layer:

- raw mode;
- alternate screen;
- terminal capability query;
- keyboard protocol;
- mouse mode;
- terminal resize polling;
- vaxis rendering;
- stdout flushing;
- terminal cleanup on exit.

TerminalHost calls FrontendCore actions instead of directly mutating all session
state.

### 4. WebHost

Future shape:

```text
browser <websocket> hexe-web-gateway <FrontendCore> SES
```

WebHost owns:

- websocket connection;
- browser resize/focus/mouse/keyboard events;
- render protocol to browser;
- browser clipboard bridge;
- authentication/session token for the web client.

FrontendCore should not need to know it is web.

### 5. SyslinkHost / remote transport

Current liblink/syslink-like code is in:

- `src/core/frontend_liblink_transport.zig`

It currently bridges byte streams through remote `hexe session pipe`.

Hardening direction:

- one authenticated connection;
- logical channels for CTL and VT;
- reconnect semantics;
- heartbeats;
- backpressure;
- explicit close/error messages;
- no raw terminal assumptions in the transport layer.

## Protocol hardening needed before web/syslink feels reliable

### A. Add CTL request IDs

Current problem:

- request/response and async events share CTL;
- sync calls read until they find the expected response;
- async events are queued as side effects.

This works locally but is fragile for web/syslink latency and reconnect.

Target:

- each request gets a `request_id`;
- responses include the same `request_id`;
- async events use `request_id = 0` or a distinct event frame;
- multiple frontend actions can safely overlap later.

### B. Add per-client VT output queues in SES

Current problem:

- SES can write VT frames directly to mux/client fd;
- slow clients can stall routing or trigger timeouts;
- remote/web transports need explicit backpressure.

Target:

- SES queues outgoing VT frames per frontend client;
- xev write readiness drains queues;
- queues have byte caps;
- resize frames are coalesced;
- output frames are fairly drained;
- slow client policy is explicit: drop, disconnect, or degrade.

Initial implementation status: SES now queues POD→MUX VT frames per mux VT fd
with a byte cap and cleanup on fd close. The periodic drain path uses
non-blocking partial writes, so slow clients no longer stall SES for the full VT
I/O timeout. libxev's dynamic `PollEvent` currently exposes read readiness only,
so the remaining hardening is write-ready draining once the backend supports it,
plus broader coalescing/drop policy if more low-value frame types appear. The
current low-value policy coalesces and drops queued duplicate `backlog_end`
frames for the same pane.

### C. Separate protocol semantics from terminal semantics

The wire protocol should define:

- frontend-generic events;
- pane lifecycle;
- session lifecycle;
- VT frames;
- resize;
- focus;
- notifications;
- clipboard;
- capability negotiation.

Terminal-specific escape/capability logic should not leak into the generic
frontend protocol.

## Migration phases

### Phase 0: Freeze the current behavior with tests

Before moving files around, add regression coverage around the behavior that must
not break:

- attach/detach/reattach preserves panes;
- abrupt frontend disconnect preserves session;
- CWD sticky floats preserve `(sticky_pwd, sticky_key)`;
- multiple per-CWD floats for one directory all restore;
- two live sessions can hand off per-CWD floats without spawning duplicates;
- terminal resize propagates to backend panes;
- pane exit, session stolen, notifications, and session snapshots are handled.

Verification:

```sh
make test
git diff --check
```

### Phase 1: Extract frontend-neutral action layer

Move action logic out of terminal-specific files where possible.

Candidates:

- from `src/frontends/terminal/loop_actions.zig`
- from `src/frontends/terminal/loop_actions_focus.zig`
- from `src/frontends/terminal/state_tabs.zig`
- from `src/frontends/terminal/state_reattach.zig`

Target modules:

```text
src/frontends/core/actions.zig
src/frontends/core/reattach.zig
src/frontends/core/session_apply.zig
src/frontends/core/floats.zig
src/frontends/core/focus.zig
```

Rule:

- action modules may depend on `FrontendRuntime` and frontend-neutral state;
- terminal modules may call actions;
- action modules must not import terminal rendering/input modules.

### Phase 2: Extract SES CTL/VT event processing

Move generic SES message handling out of terminal loop code.

Current files:

- `src/frontends/terminal/loop_ipc.zig`
- SES CTL parts of `src/frontends/terminal/loop_core.zig`
- SES VT parts of `src/frontends/terminal/loop_core.zig`

Target:

```text
src/frontends/core/ses_events.zig
src/frontends/core/vt_events.zig
```

TerminalHost should only:

- poll fds;
- read bytes/frames;
- pass events into FrontendCore;
- render when FrontendCore says render is needed.

### Phase 3: Define frontend-neutral state model

Decide what state is truly frontend-neutral vs terminal-only.

Frontend-neutral:

- tabs;
- splits;
- floats;
- focused pane/float;
- pane UUID/pane ID mapping;
- pane names;
- pane cwd/proc metadata;
- session snapshot;
- notifications as abstract events;
- pane screen model if it can be rendered by more than terminal.

Terminal-only:

- vaxis renderer state;
- terminal capability flags;
- kitty image cache;
- raw terminal cursor restore;
- terminal mouse shape;
- alternate screen lifecycle;
- terminal input parser buffers.

This is the hardest phase. Do it gradually.

### Phase 4: TerminalHost wrapper

Create:

```text
src/frontends/terminal/host.zig
```

Current status: `host.zig` owns raw mode, alt-screen setup, capability-query
startup/finalization, terminal cleanup, terminal resize polling, render
scheduling, render execution, terminal byte input dispatch, and host disconnect
handling, terminal stdin read mechanics, stop-request presentation, plus xev
loop/timer lifecycle. `loop_watchers.zig` now owns watcher storage and callback
implementations, so `loop_core.zig` is no longer the terminal fd/callback
boundary.

This file should become the terminal-specific owner of:

- raw mode;
- alt screen;
- terminal capability query;
- xev watchers for stdin/stdout/resize;
- vaxis rendering;
- terminal cleanup.

`main.zig` should become mostly:

```zig
load config
create FrontendCore
create TerminalHost
host.run(&core)
```

### Phase 5: Protocol hardening

Do this before serious web/syslink work:

1. add request IDs to CTL requests/responses;
2. keep async events explicitly separate;
3. add per-client VT output queues;
4. add capability negotiation per frontend kind;
5. add structured disconnect reasons;
6. add targeted protocol tests.

Initial implementation status: CTL now carries a `request_id` in protocol v3.
Frontend client requests allocate non-zero ids, while SES echoes ids for direct
request/reply paths and leaves unsolicited async/forwarded events at `0`. Sync
readers require the expected request id for direct replies and continue to queue
async CWD/pane/session events. A generic pending-response store now preserves
out-of-order direct replies by request id, including payload-bearing replies,
so future hosts can start overlapping CTL calls without corrupting the command
that is currently waiting.

Structured disconnect groundwork now exists in both the frontend-core host event
model and the SES wire `Disconnect` payload: hosts can distinguish transport
loss from an intentional close, and graceful frontend shutdowns now include an
advisory reason for SES logs/policy.

Capability groundwork now exists as coarse `HostCapabilities` defaults for
terminal, web, and syslink-style hosts, and registration now sends/stores a
compact capability flag set. Full policy negotiation is still pending, but SES
no longer treats frontend capabilities as an out-of-band terminal-only concept.

### Phase 6: Syslink transport hardening

Improve `frontend_liblink_transport.zig`:

- replace two independent remote exec pipes with one connection and logical channels;
- make CTL and VT channels explicit;
- add reconnect/heartbeat behavior;
- expose config/CLI options for host/user/identity/trust;
- preserve local IPC behavior as the baseline.

### Phase 7: Web gateway prototype

Only after the core/host boundary is usable:

- add `src/frontends/web_gateway/`;
- accept websocket clients;
- create a `FrontendCore` with `FrontendKind.web`;
- translate browser input/resize/focus to HostEvents;
- translate render output to browser patches;
- keep authentication basic but explicit.

## Concrete first PR / first coding pass

Keep the first pass small.

1. Add `src/frontends/core/README.md` or `doc/FRONTEND_ARCHITECTURE.md`
   documenting the boundary.
2. Add a tiny `src/frontends/core/events.zig` with host event/command types.
3. Move no behavior yet, or move only one low-risk thing:
   - notification event type; or
   - stop reason handling; or
   - session stolen handling.
4. Keep terminal behavior unchanged.
5. Run:

```sh
make test
git diff --check
```

## Risks

- Moving too much at once will break attach/reattach again.
- Terminal rendering is tightly coupled to pane state; extracting all of it in one
  pass is too risky.
- CWD sticky floats are core behavior and should be protected with tests before
  large state refactors.
- Remote/web transport will expose every hidden blocking write and timeout.

## Acceptance criteria

This refactor is successful when:

- terminal frontend behavior is unchanged;
- frontend-neutral actions can be tested without raw terminal setup;
- SES CTL/VT handling can be reused by non-terminal hosts;
- terminal-specific files no longer define the generic frontend model;
- a future WebHost can reuse FrontendCore without importing vaxis/raw terminal code;
- a future SyslinkHost can reuse FrontendCore without pretending to be local IPC.
