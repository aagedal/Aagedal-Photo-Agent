# Strict concurrency and Thread Sanitizer validation — 2026-08-21

The full current source and test targets compile under Swift 6 with complete strict concurrency,
`-warn-concurrency`, and actor data-race checks. A clean isolated build completed in 198.7 seconds;
an incremental rebuild after the asynchronous rename-preview change completed in about 60 seconds.
Neither emitted a concurrency diagnostic.

Thread Sanitizer then exercised the four workflow boundaries on macOS. Rename planning/execution
and quiescence plus delivery staging, upload, workflow, registry, receipt, assembler, and FTP suites
passed 114 logical tests (132 parameterized executions) with no race report in 47.424 seconds.
Caption session/sidecar and Deadline preflight service/coordinator added 67 logical executions with
no race report in 5.501 seconds.

Three explicit overlap regressions prove that a second upload is rejected while the active file is
owned, a second workflow start is rejected during staging, and 32 concurrent receipt repository
transactions retain every unique record. The audit also verified immutable pure rename planning,
transaction-local rename execution/rollback, MainActor quiescence around live rename writers,
actor-level staging/upload/workflow guards, active-file transport cancellation, receipt FIFO gating
around complete load/mutate/save, atomic-store non-suspending actor operations, and the registry's
atomic same-UUID directory claim. Exercised unchecked-Sendable buffers/process/test probes protect
mutable state with locks.

No production race was proven, so the concurrency slice added only the overlap regressions. Swift
parse checks, project-file lint, and `git diff --check` passed.

The evidence is scoped to exercised macOS paths. Separate processes do not share an OS lock around
same-UUID workflow removal/recreation, and independent callers could bypass the app's owner and run
separate rename executors against overlapping files; production composition prevents that through
its single modal/quiescence owner. External transport implementations beyond the tested production
adapter require their own sanitizer evidence.
