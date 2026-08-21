# Workflow performance validation — 2026-08-21

The four workflow performance boundaries now have deterministic architectural gates plus measured
results on an Apple M5 Pro development machine.

Caption navigation captures an immutable draft, enqueues JSON/XMP persistence on a FIFO background
queue, invalidates the old decode token, and publishes the new focus without awaiting either disk
I/O or full-resolution decode. Explicit mutations and workspace exit cross a durable drain barrier;
failed writes remain at the queue head for ordered retry. Gated tests measured navigation return in
0.000886 seconds with persistence held and 0.001994 seconds with decode held. Caption and sidecar
suites passed 12/12 and 27/27.

Batch Rename planning now uses immutable snapshots, a 120 ms cancellable debounce, and one serial
off-MainActor worker per sheet. Generation gating prevents a completed superseded plan from
publishing, and execution is disabled while a new plan is building. A realistic 10,000-file,
40,000-artifact plan completed in 3.824 seconds with a process-wide resident-size increase of
56.4 MiB. The actual UI remains responsive while that synchronous pure planner occupies its worker;
a queued latest plan waits for the one in-flight calculation rather than starting competing CPU
work. Twenty-two focused rename tests passed, including blocked-planner responsiveness and stale
publication refusal.

Deadline preflight now emits immutable partial reports at dependency, bounded per-image, rename,
and delivery boundaries. The coordinator generation-gates tokened progress so superseded evaluators
cannot publish, and the UI projects partial rows/counts while keeping remediation and Send disabled
until the deterministic final publication exists. Suspended progress consumers remain cancellable;
the last partial snapshot equals the final report.

Delivery's 1,000-item stress is recorded separately in
[the delivery large-batch validation](delivery-large-batch-validation.md): bookkeeping is O(item
count), while artifact-byte working memory is one item.

The final combined current-source run covered Caption, sidecar, rename planner/sheet/repository, and
Deadline service/coordinator/live-adapter suites: 114 executions, zero failures, in 6.052 seconds
using isolated DerivedData at `/private/tmp/aagedal-rename-session-async-01`. Build-for-testing and
`git diff --check` passed.

RSS and elapsed times are device/process measurements with deliberately broad regression tripwires,
not universal throughput guarantees. Caption decode uses a deterministic gate/token proof rather
than a real-codec benchmark, and queued drafts can be lost only if the process is forcibly terminated
before a durable barrier. A manual representative-device UI/accessibility pass remains required.
