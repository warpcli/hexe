# Multithreading Plan for MUX Runtime

## Goal

Improve responsiveness and frame stability by moving blocking and CPU-heavy background work off the main MUX thread, while preserving a single-owner model for UI state and terminal rendering.

## Current Constraints and Invariants

- `runMainLoop` is the control center and currently serializes most work.
- `State` is mutable shared runtime state; today it is effectively single-thread owned.
- Rendering and terminal output must remain ordered and deterministic.
- Pane VT state and render snapshots are tightly coupled to current event ordering.
- Existing code already has event-driven I/O via xev; this should stay the backbone.

## Target Concurrency Model

- Keep one **UI thread** as the only writer for:
  - `State`
  - pane collections and layout
  - vaxis screen and terminal output
- Add a small **worker pool** for background jobs only.
- Use **message passing** from workers back to the UI thread:
  - job queue (UI -> workers)
  - result queue (workers -> UI)
- Use **generation/version tokens** on requests to reject stale results.
- Keep locks out of hot render/input paths whenever possible.

## Non-Goals (for first iteration)

- No parallel writes to terminal output.
- No direct worker mutation of pane VT state.
- No immediate attempt to parallelize `vt.feed` and core render internals.

## Work Breakdown

### Phase 1: Infrastructure (Worker Runtime)

1. Add a generic background runtime module in multiplexer:
   - fixed-size worker pool
   - bounded MPSC job queue
   - bounded MPSC result queue
   - graceful shutdown and drain behavior
2. Define job/result enums with explicit payloads and generation ids.
3. Add lightweight counters/timing for queue depth, dropped jobs, and latency.
4. Integrate queue polling into `runMainLoop` at a safe point before render.

### Phase 2: Statusbar Offload (Highest ROI)

1. Move expensive statusbar evaluations to workers:
   - shell `when` conditions
   - external command outputs used by segments
   - expensive Lua-backed segment evaluation where safe
2. Keep synchronous fallback path behind a feature flag for rollback.
3. Introduce per-segment TTL and dedupe:
   - do not enqueue duplicate in-flight jobs for same key
4. UI thread always renders latest cached result; worker updates mark `needs_render`.
5. Add timeout and cancellation semantics:
   - stale generation result is dropped
   - timed out job returns failure state, never blocks UI

### Phase 3: Background Metadata Refresh

1. Offload non-critical process/cwd metadata probes to workers.
2. Keep last-known-good metadata on UI side.
3. Apply result only if pane UUID and generation still match current pane.
4. Rate-limit probe jobs to avoid churn in high-pane-count sessions.

### Phase 4: Optional Render Preparation Parallelism

1. Split render into:
   - parallel-safe precompute (labels, text shaping decisions, style resolution inputs)
   - UI-thread final draw and terminal flush
2. Ensure precompute output is immutable and short-lived.
3. Abort this phase if profiling does not show meaningful gains.

## Data Safety and Correctness Rules

- Worker threads cannot hold raw pointers into mutable UI-owned structures beyond enqueue boundary.
- Result application must verify:
  - session id
  - pane UUID (if relevant)
  - generation/version id
- Any worker failure must degrade gracefully to cached/stale UI data.
- Queue overflow policy must be explicit:
  - drop newest for low-priority jobs
  - keep latest only for coalescable jobs

## Performance and Reliability Metrics

Track before/after for each phase:

- p50/p95/p99 loop duration
- render cadence and missed 16ms windows
- input-to-render latency under load
- statusbar job latency and timeout rate
- queue depth distribution and drop counts
- CPU utilization by UI thread vs workers

## Test Strategy

1. Unit tests
   - queue behavior, dedupe, generation checks, stale result rejection
2. Integration tests
   - statusbar still updates under heavy command latency
   - no deadlocks on shutdown
   - deterministic behavior when jobs timeout/fail
3. Stress tests
   - many panes + frequent status updates + resize + popup activity
4. Regression checks
   - tab/focus changes do not apply stale async results to wrong target

## Rollout Strategy

- Add feature flags:
  - `HEXE_MUX_ASYNC_STATUS=1`
  - `HEXE_MUX_ASYNC_META=1`
- Default enable only Phase 2 initially after validation.
- Keep quick rollback path to synchronous behavior.
- Enable Phase 3 after telemetry confirms stability.
- Gate Phase 4 behind explicit opt-in until proven.

## Runtime Flags (Current)

- `HEXE_MUX_ASYNC_STATUS`
  - `1|true|on|yes` (default): enable async status worker runtime
  - `0|false|off|no`: disable async status and use synchronous path
- `HEXE_STATUS_COMMAND_INTERVAL_MS`
  - status command segment cache refresh interval (default 500ms)
  - clamped to `[50, 10000]`
- `HEXE_CONDITION_TIMEOUT`
  - timeout for shell condition checks (default 100ms)
  - clamped to `[10, 5000]`

## Rollout Guidance

1. Start with `HEXE_MUX_ASYNC_STATUS=1` in development sessions.
2. Monitor worker stats logs (`enq`, `done`, queue drops, avg job latency).
3. If queue drops increase, tune worker count and queue bounds before wider rollout.
4. Keep sync fallback (`HEXE_MUX_ASYNC_STATUS=0`) available for quick rollback.

## Risks and Mitigations

- Risk: race conditions in state application.
  - Mitigation: strict single-owner UI state + generation checks.
- Risk: queue overload under bursty updates.
  - Mitigation: bounded queues, coalescing, rate limits.
- Risk: complexity growth and debugging difficulty.
  - Mitigation: clear module boundaries, metrics, feature flags.
- Risk: low benefit for some workloads.
  - Mitigation: profile-driven progression, stop after Phase 2/3 if gains plateau.

## Commit Plan (Titles Only)

1. Add mux worker runtime and message queues
2. Integrate async result pump into main loop
3. Add generation-safe async job/result types
4. Offload statusbar shell conditions to workers
5. Offload statusbar command segments to workers
6. Add statusbar async cache, TTL, and dedupe
7. Add async status feature flag and sync fallback
8. Add async metadata probe jobs for pane process and cwd
9. Apply metadata results with pane UUID and generation guards
10. Add queue metrics and multithread timing instrumentation
11. Add unit tests for queueing, dedupe, and stale result rejection
12. Add integration stress tests for async status and metadata paths
13. Add optional render-precompute worker path behind flag
14. Document runtime flags and rollout guidance
