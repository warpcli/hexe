# Hexe Hardening Plan

Replaces the prior UI/SES separation plan (which is complete).

This plan consolidates findings from a five-agent audit (dead code, stubs,
implementation bugs, architecture, security) into a prioritized, sequenced work
list. Each phase is independently shippable — don't merge later phases before
earlier ones land.

Completion is not claimed until every checkbox in a phase is done AND the
phase's exit criteria hold.

---

## Phase 1 — Memory-safety fixes (mechanical, shippable as one PR)

Small, isolated fixes for confirmed memory-safety bugs. No design work, no
refactors.

- [x] **P1.1** — `src/core/ipc.zig:147` — `Client.connect()` now clamps the
      socket path copy via `@min(path.len, addr.path.len - 1)`, matching the
      pattern at `:40` and `:77`.
- [~] **P1.2** — `src/modules/pod/buffering.zig:40-47` — **false positive**.
      Line 32 early-returns when `data.len >= self.buf.len`, so the remaining
      path is reached only with `data.len < cap`. That invariant makes
      `drop = self.len + data.len - cap < self.len`, so the `self.len -= drop`
      at line 47 cannot underflow. Skipped.
- [x] **P1.3** — `src/frontends/terminal/state.zig:272` — `stdin_tail_len`
      widened from `u8` to `u16`. The `@intCast(tail.len)` at
      `loop_input.zig:130` is bounded by `stdin_tail.len == 256`, which fits.
- [x] **P1.4** — `src/core/pty.zig:272` — `closeExtraFds` fallback now walks
      up to `getrlimit(RLIMIT_NOFILE).cur` instead of 1024. `close_range` is
      still the primary path.

**Exit criteria:** `zig build` clean. ✅

---

## Phase 2 — Silent-failure cleanup (one-shot refactor)

Retire the ~250 `catch {}` patterns on wire writes by routing them through a
single helper that logs and marks the client connection broken.

- [x] **P2.1** — Added `Server.replyOrClose` and `Server.replyOrCloseWithTrail`
      helpers in `src/modules/session/server.zig`. Both log at warn level and
      queue the fd for close via the existing `queueCtlClose` pending path,
      which triggers `removeClientWithWatcherCleanup` on the next poll tick.
- [~] **P2.2** — No separate "broken" flag needed. `queueCtlClose` already
      feeds into the unified cleanup path used by EPIPE/ECONNRESET handling,
      so we reuse it directly. Rejected as redundant.
- [x] **P2.3** — All 50 `wire.writeControl(...) catch {}` sites in
      `server.zig` migrated to `self.replyOrClose(...)`.
- [x] **P2.4** — All 18 `wire.writeControlWithTrail(...) catch {}` sites in
      `server.zig` migrated to `self.replyOrCloseWithTrail(...)`. Also
      migrated the one `writeControlMsg(...) catch {}` at `:2283` inline
      (no helper added for a single call site).
- [x] **P2.5** — `src/core/frontend_client.zig` had two swallows: the
      shutdown `disconnect` notify (now logs at debug level — there's
      nothing else to do mid-shutdown) and `update_pane_aux` (now logs and
      nulls `self.ctl_fd` so subsequent ops fail fast).
      `frontend_liblink_transport.zig` has no `wire.writeControl.*catch {}`
      patterns.
- [x] **P2.6** — Lifecycle-specific silent failures tightened beyond wire
      writes: SES pane kill/orphan rollback failures now log; POD VT routing
      setup is atomic across pane state, routing maps, and poll registration;
      detach/reattach txlog write failures log; status response serialization
      fails closed instead of sending truncated wire data; frontend
      `pane_exited` queue/drain allocation failures log and preserve queued
      state for a later drain attempt.
- [x] **P2.7** — Projection/protocol drain hardening: `SessionProjection`
      float sync no longer creates a float without pane metadata, and rolls
      back newly inserted pane metadata if float insertion fails. Frontend
      client socket-path response trails now use chunked skipping for the
      full advertised length and poison `ctl_fd` on skip failure, avoiding
      control-stream desync. SES server CTL fd registration now fails closed
      if the fd cannot be tracked, and pending close-queue append failures
      are logged.
- [x] **P2.8** — Frontend reattach/dead-pane cleanup hardening:
      reattach UUID maps no longer drop entries silently, adopted panes are
      orphan-rolled-back if they cannot be cached, existing-pane capture
      fails the snapshot apply instead of rebuilding from a partial map, and
      dead split cleanup collection logs allocation failures.
- [x] **P2.9** — Float workflow cleanup: exclusive/per-cwd float hide-list
      allocation failures now log and notify instead of silently leaving
      visibility state inconsistent, and CLI float env construction no
      longer silently drops bookkeeping failures or leaks duplicated env
      entries when tracking fails.
- [x] **P2.10** — Terminal IPC response writes now log failures instead of
      disappearing: popup responses, exit-intent replies, float spawn failure
      results, cancelled float results, blocking float completion results,
      and pane popup cancellation replies all route through local logged
      helpers.
- [x] **P2.11** — CLI wire writes now report failures instead of returning
      apparent success: targeted/broadcast notify, popup notify, and send-key
      commands print the write error. The repo-wide
      `wire.writeControl.*catch {}` scan is now clean.
- [x] **P2.12** — SES startup/recovery failures are more visible and txlog
      durability is stricter: persisted-state load failures now log, txlog
      truncation failures during recovery log, `TxLog.init` no longer
      advertises an impossible error path, and txlog writes now propagate
      `fsync` failure so callers do not treat a non-durable transaction as
      successfully recorded. Txlog header/payload writes also now loop until
      all bytes are written, so a short `write(2)` cannot leave a partial
      transaction while reporting success.
- [x] **P2.13** — Persistence restore no longer accepts malformed pane
      `session_id` fields as undefined bytes: session-id hex parsing is
      centralized in `persist.parseSessionIdHex`, invalid values become
      `null`/skipped, and direct tests cover valid, short, and invalid-hex
      inputs. Directory `fsync` failure after atomic state-file rename now
      propagates through `persist.save` and is logged by the existing caller.
- [x] **P2.14** — Persisted session JSON now escapes all runtime/user strings
      instead of interpolating them raw. `persist.writeJsonString` is used for
      pane socket paths, sticky pwd, session names, snapshot JSON strings, and
      UUID strings; tests cover quotes, backslashes, line breaks, tabs, and
      control bytes. This prevents a single odd path/name from corrupting the
      recovery file and dropping panes on restart.
- [x] **P2.15** — Persistence load now treats malformed JSON shapes as
      recoverable corruption instead of assuming every field has the expected
      tag. Root/pane/session objects, arrays, strings, integers, pid fields,
      and u8 fields are checked before use; invalid records are skipped.
      Stored pane UUIDs are validated as 32-byte hex via
      `persist.parseStoredUuidHex`, with direct tests for valid, short, and
      invalid-hex inputs. The atomic save temp file is also created `0o600`.
- [x] **P2.16** — Session cleanup/detach silent drops removed in the hot
      attach-detach path: snapshot pruning now fails closed instead of
      persisting stale pane references, detach rollback backup allocation
      failure aborts before mutating the current pane and restores prior
      panes, cleanup collection failures log instead of `catch continue`, and
      ambiguous-session response formatting falls back to a clear error
      instead of silently truncating.
- [x] **P2.17** — Frontend sticky restore/sync silent drops reduced: startup
      `adoptStickyPanes` now logs failed SES sticky-pane queries and failed
      float adoption attempts instead of skipping them invisibly, and synced
      float resize failures log instead of disappearing. The remaining
      `state_session.zig` catch in this focused scan is a fork-child
      `execve` fallback immediately followed by `exit(1)`.
- [x] **P2.18** — Terminal pane input write drops now log with pane context:
      send-key broadcast/targeted writes, inherited-env sync writes, CSI
      reply forwarding, and mouse SGR forwarding no longer disappear behind
      `catch {}`.
- [x] **P2.19** — `Pane.write` now honors its `!void` contract by propagating
      mux VT write failures instead of swallowing them internally. Internal
      VT feed, resize frame writes, and DCS query response writes now log
      failures, so broken pane channels leave evidence instead of looking like
      lost input.
- [x] **P2.20** — Layout startup command injection no longer returns silently
      when pane input writes fail; command and newline writes now log against
      the target pane UUID.
- [x] **P2.21** — Terminal response routing and paste buffering no longer
      fail invisibly: OSC/CSI reply-target queue allocation failures log and
      roll back partial queue state, and bracketed paste buffering now aborts
      with a notification instead of delivering a partial paste.
- [x] **P2.22** — Layout-driven pane resize failures now log instead of being
      swallowed during layout recalculation and pane swaps, making bad
      restored geometry or VT resize failures diagnosable.
- [x] **P2.23** — Float frame geometry is centralized in `State` via
      `floatUsableArea`, `floatFrameFromValues`, and `floatFrameForPane`.
      New, adopted, moved, nudged, resized, and synced floats now share the
      same terminal/status/shadow/padding math, reducing the chance that
      attach/adopt paths place panes differently from live resize paths.
- [x] **P2.24** — Stored float geometry percentages are clamped before the
      `u8` UI/session fields are written. Oversized CLI float dimensions now
      resolve to bounded geometry instead of risking an integer-cast trap.
- [x] **P2.25** — SES payload-drain helpers now log failed CTL/VT skips.
      Malformed or truncated payload cleanup no longer disappears silently,
      which makes control-stream desyncs and VT route drain failures
      diagnosable.
- [x] **P2.26** — Named sticky float metadata sync failures now log and notify
      instead of disappearing after pane creation. This leaves a visible
      failure if SES rejects the post-create sticky update, rather than
      creating a float whose reclaim/adopt metadata silently diverged.
- [x] **P2.27** — Reattach reconstruction failures now leave diagnostics on
      the pane-loss paths: split/float pane allocation, `initWithPod`,
      `replaceWithPod`, restored tab append, restored float append, and
      orphan attach-as-tab append failures log before returning. This does not
      change recovery semantics yet, but removes another layer of silent
      missing-pane outcomes.
- [x] **P2.28** — The manual adopt-first-orphan path and shared
      `replacePaneWithPodSynced` helper now log failed orphan listing,
      failed orphan adoption, and local POD replacement failures before
      rollback. Failed pane swaps no longer look like a no-op with no cause.
- [x] **P2.29** — Full reattach now orphans panes back to SES if local tab
      root allocation, restored tab append, or restored float append fails
      after adoption. This prevents panes from being attached to the new
      client but absent from the terminal UI after a local reconstruction
      failure.
- [x] **P2.30** — Full reattach now also rolls back already-adopted panes if
      the adoption phase times out before local views are rebuilt, avoiding a
      pre-UI abort that leaves panes attached but unreachable.
- [x] **P2.31** — Full reattach no longer aborts after local views are rebuilt
      just because the operation crossed the post-layout timeout. At that
      point the transaction is past the clean rollback boundary, so it now
      warns and continues to `completeReattach`; the recovery-tab failure path
      also orphans already-adopted panes before returning.
- [x] **P2.32** — Full reattach now sets the restored session identity before
      adopting panes or rebuilding local views, so allocation failure there is
      still a clean abort. The remaining no-restored-tabs abort path now also
      orphans already-adopted panes before returning.
- [x] **P2.33** — SES orphan/session list responses no longer stream
      multi-part replies with `wire.writeAll(... ) catch return`. The handlers
      now build one payload and send through `replyOrClose`, so failed list
      replies close the stale control fd instead of leaving clients with
      truncated attach/adopt list data.
- [x] **P2.34** — `SessionProjection` shell/proc metadata replacement no
      longer frees old owned strings before allocating replacements. Allocation
      failures now log and preserve the previous command/CWD/process strings
      instead of leaving dangling pointers; a regression test covers failed
      replacement under a failing allocator.
- [x] **P2.35** — `SessionProjection` pane-name replacement now uses the
      existing hash-map slot when present, making rename replacement
      allocation-free and explicit. New-name insertion failures now log before
      freeing the supplied owned name, and the metadata regression test covers
      replacement while the projection allocator is failing.
- [x] **P2.36** — `SessionProjection` tab metadata/focus-memory updates are
      now transactional under allocation failure: tab-name ownership is
      protected with `errdefer`, `appendTabFocusMemory` rolls back the first
      vector append if the second fails, and `resetTabFocusMemory` builds new
      vectors before replacing the old ones. Regression coverage verifies the
      focus-memory lengths remain consistent when allocation fails.
- [x] **P2.37** — `SessionProjection.replaceAttachedSnapshotOwned` is now
      transactional. It prepares the session name, tab metadata, and tab focus
      vectors before deinitializing the old snapshot, so allocation failure
      preserves the old attached snapshot and local projection metadata. A
      regression test covers failed replacement with an existing snapshot.
- [x] **P2.38** — `FrontendRuntime` projection wrappers now log allocation
      failures when session identity, tab metadata, or tab focus memory updates
      fail. Higher-level attach/tab code still gets the same boolean result,
      but failures no longer disappear without diagnostic context.
- [x] **P2.39** — `SesClient` connection/setup and queued metadata paths now
      log previously silent failures: CTL/VT socket connect failures, CTL
      nonblocking setup failure, ping response read failure, pending session
      state/CWD queue allocation failures, and pane-info name allocation
      failure. Pane-info OOM now drains the advertised trail before returning
      so the control stream stays synchronized.
- [x] **P2.40** — Remaining pane-info snapshot OOM branches for foreground
      process and CWD allocation now log, free partial state, and drain the
      rest of the advertised response before returning. Queued control-response
      drain failures now log and poison the CTL fd instead of returning
      silently.
- [x] **P2.41** — SES CTL/VT watcher arming now fails closed. Watcher
      allocation/map-insert failures log and return failure to accept/pending
      registration paths, which then unregister/clear the fd and close it
      instead of leaving accepted control or VT fds untracked.
- [x] **P2.42** — SES client-session snapshot push serialization failures now
      log instead of silently returning. If snapshot JSON generation fails
      during attach/session mutation, the missing frontend update has an
      explicit diagnostic.
- [x] **P2.43** — Remaining `SesClient` silent connection/setup fallbacks were
      removed from the core scan. Preconnected VT nonblocking failures, CTL
      timeout setup/clear failures, reattach response allocation failures, and
      SES starter wait failures now log; `src/core/frontend_client.zig` no
      longer has `catch return` or `catch {}` sites.
- [x] **P2.44** — Terminal keybind confirmation popups now roll back
      `pending_action`, log the popup creation failure, and show a notification
      when confirmation UI cannot be created. Detach, disown, close-pane,
      close-tab, and quit actions can no longer get stuck pending behind an
      invisible failed confirmation popup.
- [x] **P2.45** — Confirmation popup failure handling is now centralized on
      terminal `State` and applied to adopt, shell-death exit, and keybind
      confirmation paths. Failed adopt confirmations also clear the selected
      orphan UUID, and failed shell-death confirmations clear the shell-death
      pending state before exiting instead of leaving the terminal wedged.
      The direct `showConfirm(... ) catch {}` scan is clean except for the
      IPC exit-intent path, which needs a custom reply fallback and now logs
      and notifies on popup creation failure.
- [x] **P2.46** — Picker popup failure handling is now centralized for
      terminal-owned picker flows and the layout save/load keybinds no longer
      disappear behind silent `catch return true` allocation/popup failures.
      Manual adopt picker creation now uses the same logged/notify fallback,
      and IPC picker/confirm creation failures log, notify, and free request
      item copies on both success and failure.
- [x] **P2.47** — Split-pane next/previous focus traversal no longer skips
      panes on allocation failure after clearing the current focus flag. The
      pane list is collected and sorted before focus is mutated; collection
      failure logs and leaves the existing focused pane intact.
- [x] **P2.48** — Terminal IPC notification and float request allocation
      failures no longer disappear silently. Notify/targeted-notify message
      copies now log allocation failure, float command/result-path allocation
      failures log and notify, and blocking float requests send an immediate
      failed `float_result` if command allocation, spawn, or pending-result
      tracking fails so callers do not wait forever.
- [x] **P2.49** — Pane environment sync command construction now logs and
      notifies on allocation failure instead of returning silently. Newly
      created/synced panes may still miss inherited environment when memory is
      exhausted, but the failure is now visible and leaves a diagnostic.
- [x] **P2.50** — Float rename buffer initialization and typed-text append
      failures now log and notify instead of silently dropping the rename
      interaction. Failed initialization also clears the pending rename UUID
      so the UI does not remain in a half-started rename state.
- [x] **P2.51** — Float UI metadata allocation failures now leave diagnostics.
      Float match regex preparation, `float_ui` map insertion, float PWD/exit
      key/title ownership, and pane float title replacement now log allocation
      failures instead of returning `false`/`null` with no context. This covers
      rename, restore/reattach, geometry, and matched visual setup paths.
- [x] **P2.52** — Mouse/statusbar action environment setup no longer silently
      drops pane UUID variables. Environment-map copy failure logs, per-variable
      insertion failure logs/notifies and aborts the action, and child wait
      failure now logs instead of disappearing.
- [x] **P2.53** — Terminal resize and pane scroll failures now log instead of
      being swallowed. Renderer resize errors after a terminal-size change and
      viewport scroll failures preserve the same UI behavior but leave
      diagnostics when the terminal view does not update as expected.
- [x] **P2.54** — Dead-pane respawn metadata sync now logs and notifies if the
      post-replacement `updatePaneAux` call fails. The replacement still
      succeeds, but missing cursor/layout/PWD metadata no longer disappears
      behind a silent `catch {}`.
- [x] **P2.55** — Paste and terminal-reply filtering allocation failures now
      leave diagnostics. Mutable paste-buffer allocation logs/notifies instead
      of dropping the paste silently, and OSC/CSI/CPR reply filter buffer
      allocation failures log before falling back to the existing pass-through
      behavior.
- [x] **P2.56** — Terminal capability setup/restore and deferred pane-name
      sync no longer swallow failures. Mouse-mode/color-scheme setup,
      detected-feature enablement, terminal reset/flush during restore, and
      deferred pane-name allocation now log failures while preserving the
      existing best-effort behavior.
- [x] **P2.57** — Statusbar state/cache mutation failures now log in the main
      condition paths. Button-click state, randomdo state initialization,
      bash condition env setup/result caching, timeout kill failure, Lua
      condition result caching, and Lua command eval caching no longer fail
      silently.
- [x] **P2.58** — Main terminal loop best-effort failures now leave logs:
      raw-mode restore failure, render failure, and layout-open helper wait
      failure no longer disappear behind silent `catch {}` while preserving
      the existing continue/cleanup behavior.
- [x] **P2.59** — Remaining statusbar cache/render silent catches in the
      touched statusbar paths now log. Builtin-description cache insertion,
      left/right command-output cache insertion, formatted-run drawing, and
      formatted-run width measurement failures preserve their existing
      best-effort behavior but now leave diagnostics.
- [x] **P2.60** — Startup/config helper failures now leave diagnostics in
      remaining terminal setup paths. Status Lua API allocation/load failures,
      key-timer scheduling failure, relative pane CWD resolution failure,
      layout shell-command allocation/fork/exec failure, and sticky-pane CWD
      lookup failure now log instead of silently returning.
- [x] **P2.61** — Statusbar Lua/shell fallback paths now log before returning
      their existing fallback values. Lua snippet allocation/load failures,
      Lua string/number/builtin/click-command conversion failures, statusbar
      shell segment spawn failure, and click Lua runtime init failure are now
      diagnosable without changing statusbar rendering semantics.
- [x] **P2.62** — Disown replacement metadata sync now logs and notifies if the
      post-replacement `updatePaneAux` call fails. The pane replacement still
      succeeds, but missing inherited creator/focus/cursor/layout metadata no
      longer disappears behind a silent `catch {}`.
- [x] **P2.63** — SES client session snapshot mutation helpers no longer drop
      focus, tab removal, or float removal updates silently when creating the
      backing snapshot fails. `updateFocus`, `removeTab`, and `removeFloat`
      now log snapshot-allocation failures before preserving the existing
      no-op fallback.
- [x] **P2.64** — SES CLI notify/status operations now report wire failures
      instead of returning silently. CLI handshake, targeted notification
      write, status request write, status header read, status payload read,
      and stdout write failures now produce a message or diagnostic so
      `hexe-ses --notify` / `--list` failures are visible.
- [x] **P2.65** — Layout/session config resolution now logs recoverable
      fallbacks that previously made layouts look simply absent. Registry JSON
      parse failure, current-directory lookup failure, directory realpath
      failure, and registry load failure now keep the existing null/empty
      fallback but leave diagnostics for local layout and named-layout lookup.
- [x] **P2.66** — Core config loading and parsing no longer silently falls
      back to defaults in the main allocation/load paths. SES config Lua
      runtime/path/load failures, local config path allocation failures,
      keybind append failures, status segment append failures, spinner kind
      allocation failure, and spinner color append failures now log warnings.
- [x] **P2.67** — Remaining focused config parser allocation fallbacks now
      leave warnings. String-list allocation, default segment name allocation,
      `when` expression string/wrapper/list allocation, nested `when` append,
      and output definition append failures keep existing fallback behavior
      but no longer vanish silently.
- [x] **P2.68** — Lua API bridge config assembly no longer drops generated
      pieces without a trace. Layout tab/float append failures and prompt
      segment append failures now log warnings and clean up the rejected
      owned values; copied layout roots also release their temporary wrapper
      allocation after ownership moves into the tab definition.
- [x] **P2.69** — User-facing SES CLI status and pane-info control paths now
      report wire failures instead of returning with no output. Status
      request/response/payload reads, pane-info request/header/body/trail
      reads, related-pane lookup queries, SES socket-path resolution,
      handshake failure, and CLI socket timeout setup now leave explicit
      errors or warnings.
- [x] **P2.70** — CLI session tree rendering no longer silently omits panes
      when temporary reporting structures fail to allocate. Pane-name map
      construction, snapshot parsing, global float collection, split-pane
      collection, and per-tab split/float child lists now emit explicit
      errors and stop rendering instead of printing a partial tree that looks
      authoritative.
- [x] **P2.71** — Remaining bare `catch {}` sites in the main CLI command
      module are gone. Layout-save server-error payload reads, layout CWD-map
      construction, and final layout-template buffer writes now report
      failures instead of silently producing incomplete diagnostics or
      truncated layout files.
- [x] **P2.72** — Terminal frame/escape forwarding writes no longer disappear
      behind bare catches. Vaxis frame flush failures now propagate through
      the existing render error path, and CSI/OSC passthrough writes to the
      outer terminal now log failures with context instead of making response
      counters and pane behavior look inconsistent.
- [x] **P2.73** — Remaining non-cosmetic terminal bare catches in blocking
      float cleanup and Kitty image sync now leave diagnostics. Result-file
      deletion failures are logged while preserving float completion/cancel
      behavior, and Kitty stale-entry collection, transfer-buffer allocation,
      image transmission, and metadata-cache update failures now log instead
      of silently leaving image/cache state unclear.
- [x] **P2.74** — The terminal frontend scan is clean of bare `catch {}`.
      Keycast label formatting now returns the partial fixed-buffer label on
      overflow, and optional sprite-loading fallbacks now log failures with
      context instead of silently disappearing.
- [x] **P2.75** — SES daemonization no longer masks stdio/session setup
      failures. `setsid`, `/dev/null` open, stdio/logfile `dup2`, logfile
      open, and final `chdir("/")` now fail daemon startup explicitly instead
      of continuing after a half-applied detach; the signal handler also avoids
      the last production bare catch with a signal-safe fallback value.
- [x] **P2.76** — POD daemonization now follows the same fail-explicit rule as
      SES. `setsid`, `/dev/null` open, stdio/logfile `dup2`, logfile open, and
      final `chdir("/")` now abort pod startup on failure instead of continuing
      with partially detached process state; stderr log redirection `dup2`
      failure now leaves a debug diagnostic.
- [x] **P2.77** — POD runtime attach/replay and metadata maintenance no longer
      hide empty-catch failures. Backlog replay and `backlog_end` writes now
      fail closed by closing the VT client instead of leaving an apparently
      attached but incomplete pane stream; PTY resize, meta sidecar write,
      metadata directory creation, alias/meta cleanup, and fd mode update
      failures now leave debug diagnostics.
- [x] **P2.78** — Standalone `pod attach` no longer hides attach I/O failures
      behind empty catches. Pod handshake failure is reported, initial and
      SIGWINCH resize failures are visible, terminal-mode restore and recorder
      input/output/flush failures log, and stdout write failure stops the
      attach loop instead of silently dropping pane output.
- [x] **P2.79** — Core IPC socket setup is no longer best-effort where failure
      breaks attach/session startup. Server socket parent directory creation,
      stale socket removal before bind, SES state/log directory creation, and
      fd cloexec/flag restore failures now either propagate or log; server
      socket cleanup and stale SES socket cleanup also leave diagnostics.
      Runtime smoke also exposed absolute socket paths under `/run/user/...`;
      IPC server access/delete/parent-directory setup now uses absolute
      filesystem APIs for absolute paths instead of treating them as cwd paths.
- [x] **P2.80** — PTY isolated-spawn setup no longer returns a broken PTY after
      parent-side namespace synchronization failures. Sync-pipe read failure,
      short sync, uid/gid map failure, done-pipe write failure, and short done
      signal now close fds, kill the child, and return an error; child cwd
      fallback failure exits instead of continuing in an unintended directory.
- [x] **P2.81** — `ses freeze` layout writing no longer silently drops pieces
      of saved layouts. The formatted file-write helper is fallible, tab/float
      separators and early closing braces propagate write errors, and split
      CWD-map insertion failure now aborts instead of producing an incomplete
      local layout file that could restore panes incorrectly later.
- [x] **P2.82** — Recording control state cleanup no longer hides stale-state
      failures. Start/status/toggle/stop stale state removal now warns on real
      delete failures, recorder process signaling failure is reported, active
      pod resolver wait failure is visible, and save-state rename fallback no
      longer silently ignores failed removal of the old state file.
- [x] **P2.83** — Recording data paths no longer silently drop captured bytes
      or corrupted flushes. `mux record` now propagates PTY/stdout/asciicast
      write failures and logs terminal-restore/flush failures; `pod record`
      reports handshake failure, logs flush failure, and bubbles asciicast
      write errors out of frame callbacks instead of continuing with a partial
      recording.
- [x] **P2.84** — Cleanup/pipe utilities no longer report success after hidden
      failures. `pod gc` now prints delete failures instead of always printing
      "deleted", and `ses pipe` now logs copy-thread failures while still
      treating normal peer-closed shutdown as benign.
- [x] **P2.85** — Shell prompt config diagnostics and prompt-module assembly no
      longer disappear behind empty catches. SHP stderr diagnostics route
      through a logged helper, and failed parsed-module appends now log and
      clean up the owned module definition instead of silently dropping/leaking
      prompt segments.
- [x] **P2.86** — Popup/overlay queue failures now leave diagnostics instead of
      invisible UI drops. Info overlay append failure, pane-select label append
      failure, and notification queue append failure now log; failed queued
      owned notifications also free their message instead of leaking.
- [x] **P2.87** — Remaining production empty catches in support paths are gone.
      Float result stdout writes, spinner final newline writes, segment cache
      insertions, Lua record-status stale state cleanup, user-namespace
      `setgroups`, and liblink bridge worker/poll/EOF/close failures now leave
      diagnostics. The only remaining `catch {}` matches are test cleanup
      defers and an explanatory logging comment.
- [x] **P2.88** — SES server control/VT `catch return` sites on core routing
      paths now leave diagnostics. Accept watcher/accept failures, POD VT frame
      header reads, control header reads, `pane_info` payload reads, and VT
      splice read/write timeouts now log before closing the affected
      connection, making attach/drop causes visible.
- [x] **P2.89** — User-facing CLI and restore `catch return` sites now report
      meaningful failures. `pod send` handshake failure, `mux float`
      handshake/request/error-response read failures, shell event socket/
      handshake/send failures, and persisted session JSON parse failure now
      leave diagnostics instead of returning as if nothing happened.
- [x] **P2.90** — CLI session JSON status output no longer silently truncates
      on stdout write failure. `outputListJson` and its string-escape helper
      are now fallible, the caller reports write failure, and the main
      `com.zig` JSON status writer no longer contains `stdout.writeAll(...)
      catch return` paths.
- [x] **P2.91** — CLI pod-list JSON output no longer silently truncates on
      stdout write failure. `outputJson` and `writeJsonEscaped` are fallible,
      and the caller reports write errors instead of returning mid-object or
      mid-array.
- [x] **P2.92** — `ses freeze` layout file generation no longer silently
      aborts on file writes or split-writer buffer failures. The Lua layout
      writer now propagates write/build errors, caps layout payload reads, and
      the CLI command scan is clean for `stdout.writeAll`/`file.writeAll`
      followed by `catch return`.
- [x] **P2.93** — `pod attach` event-loop exits now leave diagnostics instead
      of looking like normal detach. Stdin poll/read failures, input frame
      write failures, pod socket poll/read failures, and resize pipe failures
      now log with `pod_attach` context before disarming or stopping.
- [x] **P2.94** — Lua mux config parsing no longer relies on
      `catch unreachable` for string keys or silently coerces failed
      `hold_ms` number reads to zero. Invalid conversion now raises a Lua
      configuration error.
- [x] **P2.95** — Lua pane/float geometry parsing no longer converts failed
      number reads into zero-sized or zero-positioned UI. Split border colors,
      float style size/padding/color, and float definition size/position now
      raise Lua errors on failed number conversion instead of mutating layout
      state with fallback zeroes.
- [x] **P2.96** — `hexe terminal --list` no longer reports a false empty
      state when SES listing fails. Detached-session and orphan-pane list
      failures now log and warn separately, and the command suppresses
      "No detached sessions or orphaned panes" if either query failed.
- [x] **P2.97** — Reattach reconstruction now leaves diagnostics for missing
      adopt prerequisites. Failed `adoptPane`, missing adopt info, and missing
      VT fd paths in split restore, float restore, and manual orphan attach now
      log with pane UUID context instead of returning `false`/`null` silently.
- [x] **P2.98** — Session snapshot pane removal now fails closed if a split
      pane cannot be removed from the saved layout. The code no longer drops
      pane metadata while leaving a stale layout reference behind; allocation
      failures log and preserve the existing snapshot, and layout/map
      divergence logs with the pane UUID prefix.
- [x] **P2.99** — SES metadata string replacement is now allocation-safe.
      Client session names, sticky CWD/session affinity, pane names, shell
      command/CWD, cwd-change paths, and foreground process names are allocated
      before replacing old metadata; allocation failures now log/report and
      preserve the previous value instead of writing `null`.
- [x] **P2.100** — Session-name resolution and full status snapshot
      serialization no longer collapse allocation/JSON failures into missing
      names or omitted session state. `resolveSessionName` is fallible, register
      reports resolution failure, and full status closes/logs if attached or
      detached snapshot JSON cannot be serialized.
- [x] **P2.101** — SES status response assembly no longer closes CLI
      connections silently on buffer allocation failure. All status response
      appends now flow through `appendStatusBytesOrClose`, which logs the
      failed response section before closing the fd.
- [x] **P2.102** — SES CLI request tracking failures now leave diagnostics.
      Pending float request tracking and popup confirm/choose response
      tracking failures log before returning `track_failed`/closing the
      waiting CLI fd.
- [x] **P2.103** — Common SES CLI forwarding/parser failures no longer close
      without context. Header reads, malformed or oversized focus/exit/float/
      notify/send-key requests, missing mux targets, and unsupported request
      types now log through `closeCliRequest` or a paired read-error log before
      closing the CLI fd.
- [x] **P2.104** — Remaining SES notify/popup/pane-info/status parser error
      branches now share the logged close path. Targeted/broadcast notify,
      popup confirm/choose, pane-info, and status flag malformed/read failures
      now log before closing; float-request no-mux and forward-failed responses
      also leave server-side diagnostics.
- [x] **P2.105** — Dedicated SES layout/session CLI handlers now log server
      causes for failed request reads, layout export generation, detached
      session-state serialization, and layout template application. `ses
      freeze`, session-state fetch, and layout apply failures no longer rely
      solely on terse client error strings.
- [x] **P2.106** — SES orphan/session list collection failures no longer
      masquerade as empty lists. Allocation/collection failures now log and
      return explicit binary errors, and response-buffer construction failures
      log the failed list section before responding with an allocation error.
- [x] **P2.107** — SES detach/reattach failure paths now leave daemon-side
      evidence. Detach/reattach request reads, session-lock acquisition,
      force-detach failures, reattach state mutation, snapshot serialization,
      and each reattach response write now log before returning an error or
      dropping the fd.
- [x] **P2.107a** — Added a direct lifecycle regression for the
      detach -> reattach -> adopt -> commit path. It proves the detached pane
      remains in the detached session, the new client receives the restored
      snapshot, adoption transfers live ownership, and final detached-session
      removal clears the pane's detached-session marker without dropping it.
- [x] **P2.107b** — Added `zig build session-protocol-smoke`, a reusable
      runtime protocol smoke that drives a real SES daemon through frontend
      register, pane create, detach, reattach, adopt, commit registration, and
      detached-list verification. The smoke exposed and fixed a real
      force-reattach daemon panic: client cleanup now closes mux fds uniquely
      so `client.fd == mux_ctl_fd` cannot double-close.
- [x] **P2.108** — SES pane lifecycle handlers now log the server-side cause
      of pane creation/adoption/sticky failures. Create-pane request/trail/env
      allocation/spawn failures, sticky attach failures, find-sticky reads,
      orphan/adopt reads and attach failures, kill-pane reads, and set-sticky
      reads now leave diagnostics before returning client errors.
- [x] **P2.109** — SES client-session snapshot sync handlers no longer return
      silently on missing clients or unlogged snapshot mutation failures. Tab
      add/remove, float sync/remove, split pane, replace split pane, and split
      ratio messages now report unregistered/missing clients and log failed
      snapshot updates before returning binary errors.
- [x] **P2.110** — SES pane metadata and result-forwarding handlers now leave
      diagnostics. Disconnect, pane-name, pane-aux, pane-shell, pop-response,
      exit-intent-result, and float-result reads log on failure; missing
      pending CLI fds for popup/exit/float responses now warn, and oversized
      float-result trails return an explicit CLI error instead of silently
      dropping trail data.
- [x] **P2.111** — SES connection registration and snapshot pushes now explain
      missing state. Handshake reads, early handshake EOF, frontend VT session
      id reads, invalid VT session ids, POD ctl UUID reads, frontend register
      reads/name reads/client allocation, and skipped snapshot pushes for
      missing client/mux fd/snapshot now log instead of returning silently.
- [x] **P2.112** — SES watcher and VT routing failures now leave diagnostics.
      Deferred watcher-destroy allocation failures, CTL/VT watcher event
      failures, periodic timer failures, oversized VT frames, missing VT
      routes, POD VT payload allocation/read failures, MUX-to-POD header
      write failures, VT splice failures, and exit-intent forward failures now
      log before closing or falling back.
- [x] **P2.113** — Frontend pane layout-path sync no longer drops failures
      silently. Pane aux/focus/unfocus/focused-info sync, unfocus-all split and
      float sync, dead-pane respawn, and disown replacement now log
      `helpers.getLayoutPath` failures instead of sending `null` layout paths
      with no diagnostic. The frontend `getLayoutPath(... catch null)` scan is
      clean.
- [x] **P2.114** — Frontend float/result metadata allocation failures no
      longer disappear. CLI float env entries for isolation/result files,
      blocking float result-file read/copy failures, pane-info name/foreground
      process copy failures, float environment inheritance reads, and adhoc
      float env merging now log or fail explicitly instead of silently
      omitting output/env/process metadata.
- [x] **P2.115** — Frontend pane/tab spawn CWD fallbacks no longer fail
      silently. Split keybinds, tab creation, config/layout-driven pane
      creation, dead-pane respawn, disown replacement, and named-float toggles
      now log failed terminal-process `getcwd` fallbacks instead of passing
      `null` with no diagnostic. The frontend `getcwd(... catch null)` scan is
      clean.
- [x] **P2.116** — Frontend session split-sync missing-tab/layout-node exits
      now leave diagnostics. Split-pane sync, split-pane UUID replacement,
      replacement rollback, split-ratio sync, and config split-tree sync now
      log when the active tab is missing a session UUID or a split branch has
      no pane UUID instead of returning `false`/`void` with no context.
- [x] **P2.117** — Frontend tab close/orphan-adopt precondition failures now
      leave diagnostics. Closing a tab with no session UUID, adopting an
      orphan without a SES VT channel, and adopting without a focused pane now
      log explicit warnings instead of returning `false` with no explanation.
- [x] **P2.118** — Frontend reattach snapshot precondition failures now leave
      diagnostics. Reattach now logs missing attached snapshots, missing live
      tab UUIDs during incremental snapshot checks, and live/snapshot layout
      shape mismatches instead of collapsing them into unexplained `false`
      results. The focused `state_reattach.zig` `orelse return false` scan is
      clean.
- [x] **P2.119** — Frontend layout mutation precondition failures now leave
      diagnostics. Closing the focused pane now logs when the layout has panes
      but no focused UUID, and pane-node swaps now log missing layout roots or
      UUIDs absent from the layout tree instead of returning `false` with no
      reason.
- [x] **P2.120** — Frontend focus traversal stale-state failures now leave
      diagnostics. Next/previous/directional focus changes now log when a
      multi-pane layout has no focused UUID or the focused UUID is no longer
      present in the pane list, instead of silently leaving keyboard traversal
      stuck.
- [x] **P2.121** — Frontend split/resize layout precondition failures now
      leave diagnostics. Splitting the focused pane logs missing layout roots,
      stale focused panes, and focused UUIDs absent from the tree; split-ratio
      sync logs missing branch anchors; resizing logs missing focus metadata
      while preserving ordinary no-divider no-ops.
- [x] **P2.122** — Frontend CTL/VT response-drop paths now leave diagnostics.
      Queued pane-input flushes log when the SES VT channel is gone, and
      cancelled/blocking float results, failed float results, popup replies,
      and exit-intent replies now log when the SES CTL channel is unavailable
      instead of dropping the response silently.
- [x] **P2.123** — Split keybind pane-creation failures now leave diagnostics.
      Horizontal/vertical split actions now log missing focused panes and
      `splitFocused` errors, notify the user on pane-creation failure, and no
      longer collapse split spawn errors through `catch null`.
- [x] **P2.124** — Frontend session identity sync failures now leave
      diagnostics. Startup layout-config names and local-layout replacement
      names now log failed `syncSessionIdentity` calls instead of swallowing
      errors through `catch null`, so session name/tab identity drift is
      diagnosable.
- [x] **P2.125** — Frontend float UI metadata mutation failures now leave
      diagnostics. Swapping float UI state now logs which side is missing
      metadata, and setting float titles logs when float UI state cannot be
      ensured instead of returning `false` silently.
- [x] **P2.126** — Explicit float nudge failures now leave diagnostics.
      Invoked float-nudge actions now log no-active-float, stale active-float
      index, and active-float-on-another-tab cases instead of returning
      `false` with no explanation.
- [x] **P2.127** — SES client-session snapshot missing-client/pane paths now
      fail visibly. Focus, tab removal, and float removal best-effort paths
      now log missing clients or panes; fallible tab add, split, replace,
      ratio, and float-sync mutations now return `error.InvalidClient` instead
      of succeeding silently when the client is gone.
- [x] **P2.128** — SES detach/pane lifecycle cleanup paths now leave
      diagnostics. Detached snapshot pruning logs missing detached sessions and
      failed UUID-list shrink attempts, pane takeover logs missing pane UUIDs,
      and force-detach logs when no attached owner exists instead of returning
      `false` silently.
- [x] **P2.129** — SES detach pane-collection fallback now leaves diagnostics.
      Detach pane collection logs when it has no client session snapshot and
      falls back to the direct pane list, and logs the original collection
      error before attempting the fallback append path.
- [x] **P2.130** — SES shell-event pane lookup drops now leave diagnostics.
      Shell events read from POD control fds now log when no pane is registered
      for the fd instead of returning before forwarding with no evidence.
- [x] **P2.131** — Frontend key timer stale-hold state no longer crashes the
      process. The timer sweep now logs an unexpected stale `.hold` timer
      instead of hitting `unreachable`; the remaining `unreachable` scan hit is
      only the child-process post-`exec` path in PTY spawn.
- [x] **P2.132** — Frontend environment-map fallback failures now leave
      diagnostics. Layout-open helper spawning, keybind Lua query context, and
      statusbar Lua query context now log failed `getEnvMap` copies instead of
      silently continuing without environment data. The terminal
      `getEnvMap(... catch null)` scan is clean.
- [x] **P2.133** — Frontend float-title/statusbar Lua init fallbacks now leave
      diagnostics. Reattach float title preservation logs allocation failure,
      and statusbar Lua condition/command/builtin-description runtime init now
      routes through a shared logging helper instead of three `catch null`
      sites.
- [x] **P2.134** — Frontend startup/config/log fallback failures now leave
      diagnostics. Session-name change notification allocation, default log
      path allocation, config-error notification allocation, and terminal log
      file open failures now log instead of disappearing through `catch null`.
      The remaining terminal `catch null` sites are parser/callback-id helpers
      and fixed-buffer background-job notification formatting.
- [x] **P2.135** — Frontend background-job notification formatting now leaves
      diagnostics. The fixed-buffer background job count message now logs
      formatting failure instead of using `catch null`; the remaining terminal
      `catch null` scan hits are only callback-id parser helpers.
- [x] **P2.136** — Mouse-selection clipboard copy failures now leave
      diagnostics. System clipboard copy errors now log and show a short
      notification instead of returning `false` silently.
- [x] **P2.137** — Terminal stderr fallback redirection failures now leave
      diagnostics. Opening `/dev/null` for stderr fallback redirection now logs
      failure instead of returning silently.
- [x] **P2.138** — Frontend process/env metadata fallbacks now leave useful
      diagnostics. Pane env snapshot, process environ, and process stat opens
      still treat normal `FileNotFound` process-exit races as quiet absence,
      but unexpected failures now log instead of returning `null`/`false`
      silently.
- [x] **P2.139** — SES pane process/env metadata fallbacks now leave useful
      diagnostics. Pane CWD, env snapshots, process environ/comm/stat/TTY
      reads, and environment-copy allocation failures now log unexpected
      errors while keeping normal process-exit `FileNotFound` races quiet.
- [x] **P2.140** — SES foreground-process stat parsing now leaves diagnostics.
      Malformed `tpgid` fields in `/proc/<pid>/stat` now log parse failures
      instead of returning `null` silently; `src/modules/session/store.zig`
      has no remaining `catch return null` sites.
- [x] **P2.141** — SES sticky-pane PID liveness checks now leave useful
      diagnostics. `/proc/<pid>/stat` path formatting and unexpected open
      errors now log, while normal `FileNotFound` process-exit races still
      resolve quietly as not alive.
- [x] **P2.142** — Core SES IPC startup/accept fallbacks now leave
      diagnostics. Nonblocking accept flag setup, SES socket path construction,
      socket access, connect failures, and stale socket cleanup now log instead
      of collapsing into `null`/`false` with no context.
- [x] **P2.143** — SES CLI output formatting failures now leave diagnostics.
      The SES CLI print helper now logs fixed-buffer formatting failures
      instead of returning silently; the remaining focused session/core
      `catch return null` hits are intentional persistence hex validators with
      regression tests.
- [x] **P2.144** — Core config parse/status message allocation failures now
      leave diagnostics. Config parse errors, Lua runtime startup errors,
      Lua load errors, and missing-`mux` status messages now log allocation
      failures instead of losing the explanatory message through `catch null`.
- [x] **P2.145** — Core config string-list allocation failures now leave
      diagnostics. Array/string list parsing and `when.all` token parsing now
      log item duplication, append, and final slice allocation failures instead
      of silently dropping entries or conditions.
- [x] **P2.146** — Core config status/float code allocation failures now leave
      diagnostics. Float title segment-list allocation and status segment
      value/show_when/source/progress/button code duplication now log instead
      of silently dropping configured behavior. `src/core/config.zig` has no
      remaining `catch null` sites.
- [x] **P2.147** — SES environment-list shrink fallback now leaves
      diagnostics. `parseNulSeparatedEnv` still returns the valid prefix when
      shrinking the entry slice fails, but now logs the allocator failure
      instead of silently retaining the larger backing slice. The focused
      `src/modules/session` silent-catch scan is down to intentional
      persistence hex validators.
- [x] **P2.148** — API bridge prompt callback command allocation failures now
      leave diagnostics. Prompt callback-reference formatting and string
      command field duplication now log allocation failures instead of
      silently disabling configured prompt callbacks/actions.
- [x] **P2.149** — API bridge layout pane/float command allocation failures
      now leave diagnostics. Lua-defined layout pane CWD/command fields and
      mux/layout float command/title fields now log allocation failures instead
      of silently dropping user configuration.
- [x] **P2.150** — API bridge prompt segment callback/style allocation
      failures now leave diagnostics. Prompt segment value/builtin/show_when,
      progress, and button style/callback duplications now log allocation
      failures instead of silently dropping configured behavior.
- [x] **P2.151** — API bridge prompt-only callback allocation failures now
      leave diagnostics. Prompt value/builtin/progress callback duplications in
      the prompt parser now log allocation failures instead of silently
      dropping configured prompt behavior.
- [x] **P2.152** — API bridge float isolation allocation failures now leave
      diagnostics. Lua-defined float isolation profile/memory/cpu/pids strings
      now log allocation failures instead of silently dropping configured
      sandbox limits.
- [x] **P2.153** — API bridge popup style/widget allocation failures now leave
      diagnostics. Notification alignment, confirm labels, and pokemon/keycast/
      digits widget string fields now log allocation failures instead of
      silently dropping configured UI text/positions.
- [x] **P2.154** — API bridge validation/path/record allocation failures now
      leave diagnostics. Float title segment-list allocation, callback field
      path formatting, prompt validation error formatting, and record command
      finalization now log allocation failures instead of silently falling back
      to `null`.
- [x] **P2.155** — API bridge layout/prompt/record construction failures now
      leave diagnostics. Layout split node allocation, prompt output/name
      duplication, and every generated record command append/quote step now
      log failure context instead of silently returning `null`.
- [x] **P2.156** — Session layout config fallback failures now leave
      diagnostics. Tab split parsing, tab float parsing, and SES default log
      path resolution now report failures instead of silently dropping layout
      pieces or disabling requested logging.
- [x] **P2.157** — Shared Lua runtime field-reader fallbacks now leave
      diagnostics. String/integer/number conversion and string duplication
      helpers now log field/index context before returning `null`, making
      session and layout config parsing failures traceable.
- [x] **P2.158** — Terminal key/input fallback failures now leave diagnostics.
      Vaxis event parsing, ghostty key encoding, fast-path UTF-8 encoding, and
      pane-select/forwarded-text UTF-8 parsing now log debug context before
      returning `null`.
- [x] **P2.159** — Isolation cgroup lookup fallbacks now leave diagnostics.
      Reading `/proc/self/cgroup` and duplicating the discovered cgroup v2
      path now logs context before returning `null`.
- [x] **P2.160** — Remaining API bridge Lua conversion fallbacks now leave
      diagnostics. ConfigBuilder pointer reads, bind-action strings, layout
      pane fields, mux float fields, and session/float isolation strings now
      report conversion failures instead of silently returning `null`.
- [x] **P2.161** — Persistence/callback/logging parser fallbacks now leave
      diagnostics. Persisted session/pane UUID decoding, keybind/statusbar
      callback-ref parsing, logging backend initialization, and nullable
      session-model UUID parsing now report failure context before returning
      `null`.
- [x] **P2.162** — Core style parser fallbacks now leave debug diagnostics.
      Palette and hex color parse failures now report parse context before
      returning `null`, completing the non-statusline silent-fallback sweep.
- [x] **P2.163** — Terminal SES channel read failures now fail visibly. The
      VT oversized-frame drain and CTL header read loops no longer treat read
      failures as ordinary "no more messages"; they log context and close the
      stale channel so attach/reattach state cannot silently desynchronize.
- [x] **P2.164** — POD attach/backlog support fallbacks now leave diagnostics.
      FD mode changes, child shell detection, stderr log redirection, and
      accept-poll errors now log debug context instead of silently returning.
- [x] **P2.165** — POD uplink metadata fallbacks now leave diagnostics.
      SES uplink connection/handshake failures, cwd/foreground metadata reads,
      metadata cache allocation, and cwd/foreground control-message writes now
      log context instead of silently suppressing pane metadata updates.
- [x] **P2.166** — POD startup/accept/OSC metadata fallbacks now leave
      diagnostics. Default log-path resolution, alias symlink creation,
      accept-loop errors, and OSC7 cwd cache allocation now log context
      instead of silently disabling related attach/discovery metadata.
- [x] **P2.167** — SES session-name fallback formatting now leaves
      diagnostics. Suffix and random-fallback session-name formatting errors
      now log context before falling back or returning `NoSpaceLeft`.
- [x] **P2.168** — Lua runtime helper and isolation setup fallbacks now leave
      diagnostics. Built-in Lua helper injection, unsafe `package.path`
      setup, user-namespace map writes, and cgroup setup/write helpers now log
      context instead of silently disabling helper APIs or sandbox limits.
- [x] **P2.169** — Core wire wait callbacks now terminate visibly on xev
      errors. Readable/timer wait callbacks now log poll/timer failures and
      update their wait state instead of disarming silently.
- [x] **P2.170** — Remaining API bridge command/key/style fallback reads now
      leave diagnostics. Command callback field reads, removed-field lookups,
      key-sequence element reads, and float border character decode failures
      now log context before falling back.
- [x] **P2.171** — Terminal interaction/render formatting fallbacks now leave
      diagnostics. Mouse SGR formatting, DCS cursor/margin response formatting,
      and float-title/overlay/popup/notification glyph encoding now log context
      instead of silently dropping visible UI output.
- [x] **P2.172** — Terminal key formatting fallbacks now leave diagnostics.
      Keycast label writes and key text-codepoint UTF-8 encoding now log debug
      context before returning partial or empty key labels.
- [x] **P2.173** — Terminal VT bridge render fallbacks now leave diagnostics.
      Grapheme/cell UTF-8 encoding, Kitty placement rendering, and hyperlink
      URI/id allocation failures now log context before degrading output.
- [x] **P2.174** — Terminal render-loop and sprite fallbacks now leave
      diagnostics. Pane render-state retrieval, resize overlay formatting,
      sprite line buffering, and sprite color parsing now log context before
      skipping visible output.
- [x] **P2.175** — Final narrowed fallback scan is down to intentional
      low-level exits. PTY exec-failure formatting now emits a fallback error
      string, and layout replacement pane-UUID collection logs before mapping
      the failure to `OutOfMemory`. Remaining hits are logger stderr write
      failure and one explicit Lua `OutOfMemory` conversion.

**Exit criteria:** `grep -rn "wire\.writeControl.*catch {}" src/` returns
zero. ✅ Build clean. ✅

---

## Phase 3 — Protocol input validation (payload caps)

Every control-message read path must enforce `wire.MAX_PAYLOAD_LEN` before
allocating.

- [~] **P3.1** — Skipped in favor of an inline check at the single control
      entry point. A full `readControlFrame` helper would have required
      changing every handler signature; the inline cap at
      `handleBinaryCtlMessage` gets the same DoS-protection win without the
      churn.
- [x] **P3.2** — Inline `hdr.payload_len > wire.MAX_PAYLOAD_LEN` check at
      the top of `Server.handleBinaryCtlMessage` (closes the connection
      with a warn log). Same pattern added to all three
      `session_state` allocation sites in `src/core/frontend_client.zig`.
      Terminal frontend (`loop_ipc.zig`) already had the cap. CLI/status
      response readers (`ses_export`, `ses_stats`, `ses_freeze`, `com`,
      `src/modules/session/main.zig`) now cap `hdr.payload_len` before
      allocating response buffers too.
- [x] **P3.3** — Accepted SES connections are set non-blocking before the
      handshake is read, and the handshake plus binary control headers now
      use timeout-bounded reads. Because the accepted fd remains
      non-blocking, existing `wire.readExact` payload reads now hit
      `readExactTimeout`'s deadline instead of blocking the SES event loop on
      a partial adversarial frame. Applied the same non-blocking,
      timeout-bounded handshake treatment to POD accepts and SHP control
      reads. POD auxiliary input now reads exactly one framed request with
      the same deadline instead of racing a single post-handshake nonblocking
      read. Added a wire test proving a partial non-blocking control header
      returns `error.Timeout`.
- [x] **P3.4** — `src/modules/session/persist.zig`:
      - Added `MAX_SOCKET_PATH=256`, `MAX_STICKY_PWD=4096`,
        `MAX_PANES_PER_SESSION=1024` caps. Each is checked during load;
        overflowing entries are skipped.
      - Added parent-directory fsync after `renameAbsolute`; filesystems or
        descriptor modes that reject directory fsync with `BADF`, `INVAL`, or
        `ROFS` are treated as a logged durability downgrade instead of
        panicking the session daemon after the atomic rename has completed.
      - `src/modules/session/txlog.zig`: added `MAX_REPLAY_BYTES=10MB` cap
        on `readAll`. Replay stops cleanly at the cap, preserving
        already-parsed entries.
- [x] **P3.6** — `create_pane` CTL trail parsing now fails closed. Shell,
      cwd, sticky pwd, isolation profile, inherit-env UUID, env-count entries,
      and trailing length must match the advertised payload exactly; malformed
      requests now receive an error instead of spawning panes with fallback or
      partially parsed metadata.
- [x] **P3.7** — Frontend `float_request` trail parsing now fails closed too.
      Command, title, cwd, result path, exit key, isolation profile, env-count
      entries, and trailing length are validated before a float is created,
      so forwarded CLI float requests cannot silently lose trailing metadata.
- [x] **P3.8** — Frontend list-response parsing now fails closed for orphaned
      pane and detached-session lists. Truncated entries, truncated names, and
      failed name-overflow skips now log, poison the CTL fd, and return an
      error instead of reporting a partial list as success.
- [x] **P3.9** — Frontend popup choose parsing now fails closed. Truncated
      item headers/bodies, invalid item lengths, allocation failures, and
      trailing byte mismatches now abort the popup instead of showing a
      partial picker.
- [x] **P3.10** — Synchronous pane metadata response handling now fails closed
      on malformed queued pane-info/CWD responses. Bad response headers,
      truncated pane names/foreground names/CWD payloads, and oversized queued
      CWDs now log and poison the CTL fd instead of being treated as harmless
      async noise.
- [x] **P3.11** — Pane metadata request/read callers now surface those failures
      instead of masking them again. Failed CWD/process/name/snapshot requests
      log and poison stale CTL fds; sync CWD/name/snapshot payload read failures
      also log before returning their optional fallback. `getPaneAux` now
      returns the underlying protocol error instead of an empty aux struct.
- [x] **P3.12** — Remaining frontend-client pane protocol fallbacks now log
      and poison stale CTL fds: pane aux request writes, async queued pane CWD
      and pane-info consumption, and async ping writes no longer fail as
      silent false/null outcomes.
- [x] **P3.13** — SES `session_*` snapshot mutation handlers now return
      explicit protocol errors for too-small payloads and failed struct/name
      reads instead of silently returning. Malformed tab/float/split/ratio
      sync messages no longer leave the frontend waiting for an ack that will
      never arrive.
- [x] **P3.14** — SES pane lifecycle/query handlers now report malformed
      sticky lookup, orphan, adopt, kill, set-sticky, and get-CWD messages
      instead of silently returning. `kill_pane` acknowledgements also use
      `replyOrClose` so failed replies join the standard stale-fd cleanup path.
- [x] **P3.15** — SES detach/reattach handlers now report failed struct and
      session-id reads explicitly. Malformed detach/reattach requests no longer
      disappear without a response on the core attach/detach path.
- [x] **P3.16** — SES disconnect and pane metadata update handlers now fail
      closed on malformed payloads. Pane name, aux, and shell metadata updates
      report failed reads, and shell update trail lengths must match exactly
      before mutating stored pane metadata.
- [x] **P3.17** — Remaining SES async/result protocol handlers now avoid
      silent malformed reads. Popup responses, cwd/foreground/shell events,
      pane-exited notifications, exit-intent results, and float results now
      either return protocol errors to waiting control peers or log ignored
      malformed async messages.
- [x] **P3.18** — Terminal SES-to-frontend IPC handlers now fail closed on
      malformed trailing lengths and log short reads. Session-state,
      notify/targeted-notify, popup confirm/choose, shell-event, send-keys,
      pane-exited, CWD, and pane-info messages now consume or reject the
      entire advertised payload so one bad async message cannot desynchronize
      later attach/reattach state.

**Exit criteria:** a malicious ctl/status response with
`payload_len=u32_max` closes/returns instead of allocating. A corrupted
session file with a 2GB `sticky_pwd` field skips that pane and moves on. ✅
Build clean. ✅

---

## Phase 4 — Privacy fixes (file perms + password mode)

- [x] **P4.1** — `src/modules/pod/main.zig:238` — pod metadata sidecar now
      created with `0o600`.
- [x] **P4.2** — `src/core/recording/asciicast.zig:21` — recording files
      now created with `0o600`.
- [x] **P4.2b** — Additional sensitive state outputs now use `0o600`:
      `ses export` JSON, saved layout JSON, session layout registry tmp
      files, and `/tmp/hexe-isolation-error.log`. Bare
      `createFile(..., .{})` / `createFileAbsolute(..., .{})` scan is clean.
- [x] **P4.3** — Added a `pod_protocol.FrameType.password_mode` VT frame.
      The terminal frontend now emits it when ghostty's
      `pane.flags.password_input` flag changes. SES routes the frame through
      the existing MUX→POD VT path, and POD uses it to clear backlog on entry,
      suppress backlog writes while active, skip backlog replay for new
      frontend/observer attaches, and suppress auxiliary observer output
      while leaving the live frontend stream intact. Bumped the protocol
      version to 2, raised `MIN_PROTOCOL_VERSION` to 2 so older frontends
      cannot connect without password-mode signaling, and made POD use the
      shared supported-version check so a new frontend cannot silently send
      the new frame to an old POD. Audited handshake call sites and updated
      the two stale SES CLI helpers in `src/modules/session/main.zig` from
      one-byte handshakes to `wire.sendHandshake`.
- [x] **P4.4** — Confirmed. `loop_input_keys.zig:26` already calls
      `isFocusedPaneInPasswordMode(state)` before emitting keycast events.
      `state.overlays.recordKeypress` is only reached from that one call
      site, so no additional guards needed.

**Exit criteria:** new asciicast and pod metadata files are `-rw-------`. ✅
Password-mode output is live-only at POD: it is not added to backlog, is not
replayed to later attaches, and is not emitted to auxiliary observers. ✅

---

## Phase 5 — Peer authentication for frontends

- [x] **P5.1** — Added `ipc.PeerCredentials`, `ipc.getPeerCredentials`, and
      `ipc.verifyPeerUid` in `src/core/ipc.zig`. POD's
      `verifyPeerCredentials` is now a one-line wrapper around the shared
      helper.
- [x] **P5.2** — `Server.dispatchNewConnection` calls `ipc.verifyPeerUid`
      first thing. Cross-UID peers get a warn log and their fd closed
      before any handshake bytes are read.
- [x] **P5.3** — `HEXE_ALLOW_CROSS_UID=1` environment variable bypasses
      the check inside `verifyPeerUid` itself, so both SES and POD honor
      it consistently.

**Exit criteria:** a process running as a different UID cannot connect to
SES — the connection is closed pre-handshake with a log line. ✅

---

## Phase 6 — Clean up stubs, dead code, and half-wired features

Small individually but they add up to significant clarity improvements.

- [x] **P6.1** —
      - `src/modules/session/main.zig` — stub `printLayoutTree()` deleted.
      - `src/frontends/terminal/mouse_selection.zig` — **false positive**.
        `EdgeScroll.up/down` are actually consumed at
        `loop_core.zig:607-611` (real `p.scrollUp(1)` / `p.scrollDown(1)`
        calls). Kept.
      - `src/frontends/terminal/keybinds.zig:694` — **false positive**. The
        enclosing `if (t.kind == .hold) { ...; continue; }` at `:663` already
        handles the `.hold` case with an early `continue`, so the inner
        switch arm is genuinely unreachable. The `unreachable` is correct.
      - `src/modules/session/state.zig:2016` — **false positive**.
        `removeDetachedSession` still exists at `:2074`. Comment is
        accurate.
- [x] **P6.2** — `listStatus(full_mode)` param deleted along with the
      unused `SesArgs.full` field and the `--full`/`-f` flag parsing. The
      four allocator-ignoring signatures now carry doc comments that
      explain the post-fork invariant; call sites (especially tests passing
      `testing.allocator`) keep working unchanged.
- [x] **P6.3** — Deleted five dead `MsgType` variants (`title_changed`,
      `query_state`, `pod_register`, `shp_prompt_req`, `shp_prompt_resp`)
      from `src/core/wire.zig`. Left reservation comments on the wire
      numbers so the values don't silently get reused with different
      semantics.
- [x] **P6.4** — Closed the cheap Lua API completeness gap for
      `hexe.mux.splits.setup`: the builder path now parses the full
      `style` table (`vertical`, `horizontal`, and all junction characters)
      instead of only `separator_v` / `separator_h`. Also aliased
      `hexe.shp.segment` to the existing shared `hexe.segment` helper table
      instead of leaving an empty placeholder. Finally removed the misleading
      `hx.mux.float.define` silent no-op: the API now raises a clear error
      directing users to `hexe.ses.layout.define({ floats = ... })`, and the
      unused `MuxConfigBuilder.floats` storage is gone.
- [x] **P6.5** — **False positive**, resolved differently than planned.
      `MuxConfigBuilder.build()`, `SesConfigBuilder.build()` are real and
      called from `config.zig`. `ShpConfigBuilder` is consumed field-by-
      field in `shell/main.zig:395`. `PopConfigBuilder` is consumed via
      `config.applyBuilder(pop_builder)` in `popup/config.zig:113,143`.
      Only the top-level aggregator `ConfigBuilder.build()` was a stub with
      zero callers — deleted, with a comment explaining how the sections
      are actually consumed.
- [x] **P6.6** — Removed the unused `PanesConfig` placeholder type and
      `core.PanesConfig` re-export. It had no fields, parser, or internal
      use sites.

**Exit criteria:** all false positives documented so they don't come back
in the next audit. Real dead code is gone. ✅ Build clean. ✅

---

## Phase 7 — Test coverage (blocking for Phase 8)

Before touching architecture, lay down a safety net so refactors don't break
silently.

- [x] **P7.1** — `src/core/wire_test.zig` — 6 round-trip tests: ping
      (empty payload), `PaneUuid` (fixed struct), `Notify` (struct + trail),
      `SessionSyncFloat` (dense struct with many fields), oversize-header
      `MAX_PAYLOAD_LEN` trip, and `Error`/trail. Good enough to catch
      byte-layout drift without writing one test per `MsgType`.
- [x] **P7.2** — `src/frontends/terminal/fast_path_test.zig` — 11 tests
      pinning `fast_path.fastPathBytes` behavior: bare space, letters,
      Alt-prefixed, Ctrl+letter → C0, Ctrl+space fall-through, Super
      fall-through, arrow keys, char-without-codepoint, multi-byte UTF-8.
      Required a small extraction: `fastPathBytes` now lives in
      `src/frontends/terminal/fast_path.zig` (dependency-light, just `std`
      + `core.Config`) so tests don't drag in the full frontend. The
      explicit `bare space → 0x20` case is the direct regression guard for
      the space-key bug.
- [x] **P7.3** — `src/modules/session/state_test.zig` — three tests
      exercising `removePaneFromSessionSnapshot` directly: float removal,
      split removal with focus fallback, and tab collapse with parent_tab
      reindex in later tabs. The third test caught a real bug: two
      reindex loops ran over `snapshot.panes` after a tab collapse,
      causing float pane entries to be decremented twice (or decremented
      then cleared). Fixed by fusing the split/float reindex into a single
      loop with a `kind` switch inside `SesState.removePaneFromSessionSnapshot`.
      Also flipped the helper `pub` so tests can call it directly.
- [x] **P7.4** — Extended `state_test.zig` with two corruption tests:
      `TxLog: readAll stops cleanly on truncated trailing entry` and
      `TxLog: readAll rejects per-entry payload_len over 1MB cap`. Both
      verify the replay terminates cleanly with the prefix preserved.
      Also fixed two pre-existing failing `findStickyPaneWithAffinity`
      tests that used dead `child_pid`s; they now use `std.os.linux.getpid()`
      so the `isPidAlive` filter doesn't reject the synthetic panes.

**Exit criteria:** `zig build test` passes, including the session state tests,
the direct SES server ownership-guard tests, wire protocol round trips, and
the fast-path suite. The fast-path suite has an explicit `bare space → 0x20`
regression test. Session state coverage now also includes a detach regression
test proving intentional POD VT routing teardown closes/removes routing
without deleting the detached pane. ✅

---

## Phase 8 — Architectural fixes (requires Phase 7 safety net)

These are the cross-cutting fixes that need tests in place first.

- [x] **P8.1** — Killed the genuine shadow state in `SessionProjection`:
      deleted fields `local_floats`, `active_tab`, `active_float_uuid`,
      `focused_pane_uuid`. Getters (`activeTab`, `activeFloatUuid`,
      `focusedPaneUuid`, `paneMeta`, `floatState`) now read from
      `attached_snapshot` directly; setters write once into the snapshot
      (no-op when detached — matches prior init defaults). `syncFloatState`,
      `removeFloatState`, `setFloatVisibleOnTab`, `toggleFloatVisibleOnTab`,
      `setFloatGeometry`, `swapFloatGeometry`, `reindexFloatParentTabsAfterRemovedTab`,
      and `normalizeFloatParentTabs` all mutate snapshot state in place via a
      small `findFloatPtr` helper — no parallel writes.
      `replaceAttachedSnapshotOwned` dropped the `local_floats` rebuild loop
      and the three redundant setActive\* calls since those fields now live
      only on the snapshot.
      **Intentional scope deviation:** `pane_shell`, `pane_proc`, and
      `pane_names` are listed in the P8.1 bullet but are NOT shadows of
      anything — the snapshot has no shell/proc/name data at all. They hold
      frontend-local runtime data populated from shell integration and proc
      scraping, orthogonal to session layout/identity. The exit criterion
      ("no fields that shadow `attached_snapshot`") is what actually matters
      and it's satisfied. Moving these to `FrontendRuntime` proper would be a
      mechanical rename without a real semantic win — left as-is.
- [x] **P8.2** — Ownership enforcement via `Client.snapshotOwnsPane` /
      `snapshotOwnsTab` and `Server.requireSnapshotPane` /
      `requireSnapshotTab`. Both helpers were already in place, wired to
      `session_remove_tab`, `session_remove_float`, `session_split_pane`,
      `session_replace_split_pane`, and `session_set_split_ratio` (tab uuid
      only). `session_close_split_pane` was removed; live split close is now
      represented by `kill_pane`, and dead-pane cleanup is SES-owned. I filled the gap: added
      `requireSnapshotPane` on both `first_anchor_uuid` and
      `second_anchor_uuid` for `session_set_split_ratio` so anchor
      references are validated too. Added four unit tests in
      `state_test.zig` covering the helper contract (pre-first-sync
      bypass; known-accept / unknown-reject for both pane and tab).
      Added `src/modules/session/server.zig` to the test suite with two
      direct guard tests proving `Server.requireSnapshotPane` and
      `Server.requireSnapshotTab` emit binary `error` responses for unknown
      UUIDs, plus handler-level binary tests for `session_remove_tab`,
      `session_remove_float`, `session_split_pane`,
      `session_replace_split_pane`, and `session_set_split_ratio`. Those
      tests prove stale frontend UUIDs are rejected through the actual SES
      control handlers before canonical session snapshots are mutated.
      **Intentional non-coverage:** `session_add_tab` creates new uuids,
      `session_sync_float` is an upsert (may create), and
      `focused_pane_uuid` optional fields in split/replace handlers can
      legitimately refer to a uuid being created in the same op — guarding
      those would break the create path. The helpers' "no snapshot yet
      returns true" semantic preserves first-registration ordering.
- [x] **P8.3** — Split `SesState`.
      `src/modules/session/state.zig` — extract:
      - [x] `SessionStore` (panes, clients, detached_sessions, session
        ownership) plus the pane/client/detached-session domain types now
        live in `src/modules/session/store.zig`; `state.zig` re-exports
        `PaneState`, `PaneType`, `Pane`, `Client`, `DetachedSession`,
        `DetachedSessionState`, and `SessionStore` for compatibility.
      - [x] `Persistence` (txlog + session file I/O) now lives in
        `src/modules/session/persistence.zig`; `state.zig` re-exports the
        type so `SesState` and any external references keep the same name.
      - [x] `PollingState` (pending_poll_fds, pending_remove_poll_fds) now
        lives in `src/modules/session/polling.zig`; `state.zig` re-exports
        the type and `SesState.polling` remains unchanged for the server
        poll-loop integration.
      - [x] `SessionLocks` (mutation serialization) now lives in
        `src/modules/session/locks.zig`; `state.zig` re-exports
        `SessionLockState`, `SessionLock`, and `SessionLocks` for
        compatibility with existing tests and server call sites.
      - [x] Snapshot mutation helpers now live in
        `src/modules/session/snapshot.zig`; `state.zig` keeps
        `SesState.removePaneFromSessionSnapshot` as a compatibility alias for
        existing tests and callers.
      - [x] Layout-template parsing/building helpers now live in
        `src/modules/session/layout_template.zig`; `state.zig` keeps only the
        SES-facing orchestration that creates/kills panes and mutates the
        client snapshot.
      - [x] Session-name conflict scanning and unique-name resolution now live
        in `src/modules/session/session_names.zig`; `state.zig` keeps
        `SesState.resolveSessionName` as a compatibility wrapper for server
        call sites and tests.
      - [x] POD VT connection and route-map setup now lives in
        `src/modules/session/vt_routing.zig`; `state.zig` keeps
        `SesState.connectPodVt` as the lifecycle-facing wrapper used by pane
        creation and backlog replay.
      - [x] Detached-session remove/list/name-or-prefix lookup helpers now
        live in `src/modules/session/detached_sessions.zig`; `state.zig`
        keeps the existing public methods as wrappers for server and recovery
        call sites.
      - [x] Sticky-pane lookup and PID liveness checks now live in
        `src/modules/session/sticky_panes.zig`; `state.zig` keeps
        `findStickyPane*` wrappers for server/frontend-runtime call sites and
        uses the shared liveness helper for dead-pane pruning.
      - [x] Orphan-pane and detached-session cleanup/kill helpers now live in
        `src/modules/session/cleanup.zig`; `state.zig` keeps the public
        cleanup/list/kill wrappers used by the server and tests.
      - [x] Re-detach replacement now uses `fetchPut` after the replacement
        state is fully built, so a failed allocation/snapshot build no longer
        drops an older recoverable detached session before the new one exists.
        The explicit `detachSession` path now follows the same ordering: it
        builds and commits detached state before mutating pane ownership or
        deinitializing/removing the client, avoiding half-detached clients if
        the session-map write fails.
      - [x] `detachSessionDirect` now reports success/failure. `removeClient`
        no longer removes a keepalive owner after a failed auto-detach without
        first falling back to pane cleanup, and forced attach only sends
        `session_stolen` after detached recovery state has been committed.
      - [x] Pane creation now validates the target client before spawning a
        POD and kills the newly created pane if appending its UUID to the
        owning client fails, preventing attached panes that are absent from
        the owner client list.
      - [x] Pane creation errdefer ownership was corrected: before insertion
        local cleanup owns the allocated name/socket/sticky pwd, and after
        insertion `killPane` owns cleanup. This removes a double-free path on
        POD VT attach or client-list append failure.
      - [x] POD spawn argument/env/handshake code and unique pane-name
        generation now live in `src/modules/session/pane_spawn.zig`;
        `state.zig` keeps only lifecycle orchestration around create/attach.
      - [x] Pane ownership transfer, attach, backlog replay, suspend, and
        `paneAttachedToClient` helpers now live in
        `src/modules/session/pane_lifecycle.zig`; `state.zig` keeps public
        wrappers for server/tests. `killPane` now also delegates there, keeping
        pane/client/detached snapshot pruning and VT route teardown in one
        lifecycle module.
      - [x] Client-owned pane collection and snapshot pruning-to-owned-pane
        list now live in `src/modules/session/client_panes.zig`, removing
        duplicate fallback loops from remove/shutdown/detach paths.
      - [x] Client add/get, graceful removal, and shutdown now live in
        `src/modules/session/client_lifecycle.zig`.
      - [x] Explicit detach, direct auto-detach, reattach seeding, forced
        detach, and stale detached-pane pruning now live in
        `src/modules/session/detach_lifecycle.zig`.
      - [x] Client session snapshot mutations (focus, tab add/remove,
        split/replace/ratio, float sync/remove) now live in
        `src/modules/session/client_session_snapshot.zig`.
      - [x] Layout-template application now lives in
        `src/modules/session/layout_apply.zig`; it still calls the public pane
        lifecycle methods for create/rollback/kill, so `state.zig` only keeps
        the server-facing wrapper.
      - [x] Pane creation now lives in `src/modules/session/pane_creation.zig`,
        including POD spawn orchestration, store insertion, VT attach rollback,
        and client pane-list registration rollback.
      - [x] `removeClient` now lives in
        `src/modules/session/client_lifecycle.zig`, using the extracted direct
        detach transaction and shared pane collection fallback helpers.
      - [x] Public `SesState` API forwarding now lives in
        `src/modules/session/api.zig`; `state.zig` is down to the composition
        fields, `init`, and one-line aliases for API compatibility.
      Keep `SesState` as a thin composition struct that owns the four
      substructs. Don't change external APIs in this phase; only internal
      structure. Final size: `src/modules/session/state.zig` is ~104 LOC,
      under the <150 LOC exit target.

**Exit criteria:** `SessionProjection` has no fields that shadow
`attached_snapshot`. Every `session_*` handler has a test proving it rejects
a pane_uuid the client doesn't own. `SesState` is < 150 LOC after the split.

---

## Out of scope (for now)

These showed up in the audit but aren't on the plan. Revisit after Phase 8:

- **Liblink transport polishing** — the remote transport is untested; either
  drop it or write an integration test harness. Not urgent until a user
  actually needs remote attach.
- **Config hot reload** — nice-to-have but requires runtime config diffing
  and keybind rebuild. Too big for this pass.
- **`MuxConfigBuilder` TODO items** (`:802` empty `hx.shp.segment` table) —
  belongs to a separate "Lua API completeness" pass once `shp` is actually
  consumed anywhere.
- **Orphan PTY reaping on SES crash** — needs a supervisor model. Deferrable.
- **Landlock isolation rules** — the constants are defined but unused.
  They're load-bearing for future work; leave them.

---

## Working order

1. Phase 1 (memory safety) — can ship today, no dependencies.
2. Phase 2 (silent failure cleanup) — ship after Phase 1 so broken-client
   handling doesn't collide with the ipc fix.
3. Phase 3 (input validation) — independent of Phase 2; can be parallel if
   someone else is on P2.
4. Phase 4 (privacy) — independent; small PR on its own.
5. Phase 5 (peer auth) — small, independent.
6. Phase 6 (dead code / stubs) — independent; fine to interleave as cleanup
   commits alongside earlier phases.
7. Phase 7 (tests) — must be done before Phase 8.
8. Phase 8 (architecture) — final, after the safety net is in place.

Phases 1–6 are shippable as individual PRs. Phase 7 unblocks Phase 8.
