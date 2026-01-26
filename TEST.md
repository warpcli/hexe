# Test Plan (proposed)

This repo is a Zig project that builds a multi-process terminal multiplexer with 4 main components:

- `hexe mux`: UI (disposable)
- `hexe ses`: session daemon + VT router (persistent)
- `hexe pod`: per-pane PTY owner + scrollback buffer
- `hexe shp`: per-command shell hook + prompt renderer

The goal of tests here is to catch regressions in:

- binary wire formats (control + VT frames)
- pane lifecycle semantics (create/detach/reattach/orphan/sticky)
- scrollback replay ordering and `backlog_end` signaling
- keybinding parsing and input pipeline (CSI-u and legacy)
- layout/state serialization stability
- prompt rendering/format parsing

## How to run in CI

1. Build:

```sh
zig build -Doptimize=ReleaseFast
```

2. Tests (recommended future): add a `zig build test` step in `build.zig` to run all `test "..."` blocks.

3. Tests (works immediately, without build integration): run Zig tests directly for the files that already contain `test` blocks.

```sh
zig test src/core/strings.zig -O ReleaseFast
zig test src/core/uuid.zig -O ReleaseFast
zig test src/cli/commands/shared.zig -O ReleaseFast
zig test src/modules/shp/format.zig -O ReleaseFast
zig test src/modules/pod/main.zig -O ReleaseFast
```

## Test categories to add

### 1) Unit tests (pure logic, fast)

These should not spawn processes or require a real terminal.

- Wire protocol encoding/decoding
  - Ensure the 6-byte control header (`msg_type`, `payload_len`) roundtrips.
  - Ensure MUX VT header (pane_id/type/len) and POD VT header (type/len) roundtrip.
  - Reject short reads, oversized payload_len, and malformed frame types.
  - Target files: `src/core/wire.zig`, `src/core/pod_protocol.zig`, `src/core/ipc.zig`.

- Keybinding/config parsing
  - Validate config schema invariants: unknown action names fail cleanly; invalid types are errors (not silent defaults).
  - Regression tests for `pane_select_mode` and `keycast_toggle` action parsing.
  - Test `when` predicates (context/program filters) including nested any/all cases if supported.
  - Target files: `src/core/config.zig`, `src/modules/mux/keybinds.zig`, `src/modules/mux/input_csi_u.zig`.

- Ring buffer / backlog correctness
  - Wrap-around behavior: write > capacity and verify oldest data dropped.
  - `backlog_end` semantics: replay drains exactly the buffered bytes and then signals end.
  - Clear-sequence handling if the POD normalizes scrollback resets.
  - Target files: `src/modules/pod/main.zig` (already has a ring buffer test).

- Serialization/golden snapshots
  - Layout/state serialize then parse/restore and compare structural equality.
  - Snapshot JSON output to detect accidental format drift.
  - Target files: `src/modules/mux/state_serialize.zig`, `src/modules/mux/state_sync.zig`.

- Prompt renderer
  - `shp` format parsing: inputs -> AST -> render tokens.
  - Segment output stability for a fixed synthetic environment.
  - Target files: `src/modules/shp/format.zig`, `src/core/segments/*.zig`.

### 2) Integration tests (socket-level, minimal terminal dependence)

These tests should spawn daemons and talk to unix sockets directly, but avoid full-screen terminal rendering.

Design: implement a small "test client" that can:

- create a unique `HEXE_INSTANCE` (temp dir / unique name)
- start `hexe ses daemon` in the background
- connect to `ses.sock` with the documented handshake
- send control messages and read replies
- optionally open the VT data channel and decode frames

Suggested cases:

1. SES handshake + ping
   - Connect control channel [1], `register`, expect `registered`.
   - Send `ping`, expect `pong`.

2. Pane creation + output routing
   - `create_pane` running `sh -c 'printf hello; exit 0'`.
   - Open channel [2] and assert an OUTPUT VT frame contains `hello` for the returned `pane_id`.
   - Assert a `pane_exited` control message arrives eventually.

3. Backlog replay
   - Create pane that prints N lines with a small delay.
   - Disconnect VT channel (simulate mux restart).
   - Reconnect VT channel and verify:
     - backlog frames arrive first
     - then a zero-length `backlog_end` frame per pane
     - then live output continues (if the process still runs)

4. Detach/reattach session
   - Connect as mux, create 2 panes, detach with a tiny layout JSON.
   - Start a second mux client, call `reattach` by prefix.
   - Validate `session_reattached` contains the expected pane UUIDs.

5. Orphan/adopt semantics
   - Orphan a pane, list orphaned panes, adopt it from a new client, verify it disappears from orphan list.

6. Sticky find/set
   - Set sticky for (pwd,key) and verify `find_sticky` returns the same pane later.

Where this plugs in:

- Prefer `zig test`-based integration tests under `src/**` (so they can access internal modules), or a dedicated `tests/` directory if the build is later expanded.
- The test harness should create and clean up its own runtime dir (`XDG_RUNTIME_DIR`) and instance name (`HEXE_INSTANCE`) so parallel CI runs do not collide.

### 3) CLI smoke tests (non-interactive)

These are shell-level tests that validate command wiring and basic ergonomics.

- `hexe ses daemon` starts and creates a socket for a unique instance.
- `hexe ses status` reports running.
- `hexe pod new` creates a pod; `hexe pod list -j` includes it; `hexe pod kill` terminates it; `hexe pod gc -n` does a safe dry-run.

Implementation note: CLI smoke tests are easiest via a small script runner in CI, but can also be done inside Zig integration tests by spawning child processes.

### 4) Fuzz/property tests (targeted, later)

- Fuzz frame parsers: control header + VT headers, with random payload lengths.
- Fuzz CSI-u decoder.
- Property: encode(decode(bytes)) == bytes for valid frames.

## Regression focus (what contributors commonly break)

- Binary protocol compatibility: sizes/alignment and payload length calculations.
- Async control behavior: avoid introducing synchronous waits on the CTL fd.
- Backlog replay ordering: backlog must complete before live streaming resumes.
- Layout persistence: state JSON format changes should be intentional and covered by snapshots.
- Input parser: platform differences in escape sequences.
