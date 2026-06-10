# Frontend core boundary

`src/frontends/core` is the frontend-neutral boundary between Hexe's session
runtime and concrete hosts.

Concrete hosts own I/O surface details:

- terminal raw mode, terminal capability probing, vaxis rendering;
- future web websocket/browser rendering;
- future syslink/SSH-like transport details.

Frontend-core modules own concepts that every host needs:

- host events and host commands;
- stop/disconnect semantics;
- frontend-neutral action and direction normalization;
- frontend-neutral CTL/VT protocol classification helpers;
- frontend-neutral session view projection from canonical SES snapshots;
- frontend-neutral action and session event types;
- future CTL/VT event processing that should not depend on terminal rendering.

Rules:

- frontend-core code may depend on `src/core` session/runtime protocol types;
- frontend-core code must not depend on `src/frontends/terminal`;
- terminal/web/syslink hosts may depend on frontend-core;
- CTL/VT semantic classification belongs here before host-specific dispatch or
  rendering logic handles it;
- concrete host entrypoints should hide their loop/transport details behind a
  host adapter, even while deeper ownership moves incrementally;
- terminal raw-mode, screen-mode, capability-query startup, and cleanup belong
  to the terminal host adapter, not the frontend core or generic loop;
- behavior movement into frontend-core should be incremental and test-covered.
