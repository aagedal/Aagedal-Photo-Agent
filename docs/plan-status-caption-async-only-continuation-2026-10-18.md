# Caption asynchronous durability APIs — 2026-10-18

This continuation moves Caption queue-admission identity lookup off the caller, removes obsolete
synchronous persistence bridges and verifies asynchronous durability. It adds no UI.

## Current-state finding

The earlier performance continuation recorded synchronous Caption persistence warnings. Current
production navigation, explicit mutations and termination already use asynchronous queue barriers.
The remaining semaphore bridges were compatibility methods exercised by tests, not evidence of a
current production Caption save stall. Inspection did find provider-backed symlink resolution in
synchronous queue admission and a recovery lookup even when no conflict review was active.
Those paths are corrected below. No measured application-speed claim is made; the Thread
Performance Checker and representative-volume release gates remain open.

## Changes

Admission now allocates its request ID and increments the nonblocking pending counter before
returning. Photo canonicalization and item construction run on the retained background queue,
in FIFO order with subsequent admissions and recovery/barrier commands. A blocked provider
lookup therefore retains pending durability without blocking the caller's actor. Canonical
photo identities still group aliases for recovery. Recovery checks return immediately when no
review is pending or active; active review alias comparisons remain unchanged.

`CaptionDraftPersistence.persist`, `CaptionDraftPersistenceQueue.drain`, synchronous queue count,
and synchronous coordinator flush methods are removed. Captured replay remains asynchronous;
queued writes retain their admitted FIFO head across suspension, cancellation and durable completion.
The lightweight `hasPendingWork` snapshot remains nonblocking. Ordered diagnostics now await
`pendingCountWhenIdle`, preserving the previous observation's wait-for-idle and failed-head semantics.

Six test files now await actual asynchronous replay/barriers rather than blocking through compatibility
methods or nesting detached tasks around them. Conflict preservation, idempotent replay, retry attempt
counts, FIFO, direct mutations, JSON/XMP failure recovery and termination capture assertions remain.
A new gated test holds a write, starts an ordered queue observation on MainActor, and verifies an
independent MainActor task runs before releasing persistence. It then joins the query and confirms
zero pending requests; a bounded watchdog prevents a blocking regression from hanging the suite.
A second test injects a held photo-identity lookup and confirms MainActor admission returns with
pending work published, the write runs only after the lookup is released, and the queue drains.

## Verification

Focused Caption/termination/mutation suites: 145 tests passed before the admission change. Full
regression after it: 4377 tests in 424 suites passed (default signing; a run with
`ENABLE_HARDENED_RUNTIME=NO` fails only the signed-MCP-helper runtime-flag check, as expected).

## Remaining qualification

Native QA reconnection again returned `Sky Computer Use native pipe closed before response` when
selecting the disposable QA application. Native shortcut reassignment/invocation, Save/signing,
accessibility, representative storage/export timing, metadata interoperability, real FTP endpoints
and signed-release qualification remain open. Metal MDB_MAP_FULL diagnostics remain unresolved.
