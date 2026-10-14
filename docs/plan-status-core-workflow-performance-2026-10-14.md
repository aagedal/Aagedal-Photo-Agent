# Core workflow performance continuation — 2026-10-14

This continuation focuses on image navigation, folder navigation, tagging and metadata
writing in the 3.0 implementation. It does not close the release performance gate.

## Changes

Loupe navigation maps at most nine neighboring image URLs instead of mapping the entire
visible folder on every arrow press. Directional target ordering, edges and adaptive
memory limits remain the same; equivalence coverage includes a 50,000-image inventory.
Speculative sidecar/settings/orientation preparation runs on a retained Dispatch worker.
Preparation and decode identities guard publication, including clear, image invalidation,
Develop suppression and replacement navigation. Foreground requests can await preparation
and reuse the exact orientation/render variant. Suppression and task revocation are atomic.

Sidebar roots, lazy expansion and child disclosure prefetch share a deduplicated queue.
Only one speculative directory read is outstanding, so wide folders cannot enqueue hundreds
of filesystem actor jobs ahead of a newly opened image folder. Explicit expansion overtakes
queued siblings. Periodic sweeps run sequentially and skip overlapping timer ticks; explicit
refresh replaces the old sweep. Failed discovery remains uncached and retryable. Recursive
removal invalidates pending discovery and cancels refresh, preventing removed or renamed
trees from reappearing after an awaited read. Initial folder discovery now awaits the
Dispatch-backed filesystem actor directly, preserving cancellation from folder replacement.
Photo scans reject unrelated extensions before provider availability probes/download requests.

Structured tagging caches keyword paths, normalized canonical/synonym names, exact-match
lookup and picker lists per local/library revision. Cache hits still observe both revisions.
First-match tree order, ancestor activation, synonyms and search limits retain their behavior;
replacement, clear and active-library changes invalidate the index.

Rating/label/orientation write completions update the affected sorted, visible and selected
snapshots using URL indexes. Full sort/filter reconciliation occurs when order or filter
membership changes, including rollback after failed writes. Unchanged sort keys no longer
trigger whole-folder sorting for each photo in a batch or restart selected-image rendering.
Source revision capture now retains a dedicated Dispatch executor. Complete stat/hash/stat
verification, serialized admission, cancellation and task-local context remain intact.
No hashing, conflict, preservation or recovery checks were removed.

## Verification

Two sub-agents implemented and reviewed independent navigation and tagging/metadata slices.
Independent review also identified and closed refresh resurrection and non-atomic suppression
races. Integrated testing exposed a fast-decode handoff race between independent cache/task
lookups; both are now read under the publication lock, with twelve-reader shared-decode coverage. Regression tests cover a 200-child sidebar queue, duplicate requests and prioritization,
removed trees during discovery/refresh, retryable failures, provider-probe filtering,
64-photo completion snapshots and failed-rating filter reentry, keyword cache invalidation,
Dispatch context, blocked prefetch revocation and newer navigation ownership.

The preliminary focused run passed 54 tests in four suites. The expanded focused run passed
110 tests in eight suites, including the synthetic slow-volume gate, with zero failures/skips.
The first unrestricted-parallel integrated attempt accumulated timing failures and stalled;
its own test processes were stopped. The repository's documented bounded configuration then
completed 4,118 tests with the fast-decode handoff failure and one stale source-audit assertion
for the unchanged Creator label. The handoff was fixed; the audit now checks the actual
`OrderedCreatorsEditor`, current Creator label and existing semantic/accessibility identifiers.
The final integrated run passed 4,117 tests with two opt-in Sony skips and zero failures
(4,119 total in 401 suites, 135.857 seconds). Its result bundle is
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_12-53-24-+0200.xcresult`.
The focused bundle is
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_12-45-38-+0200.xcresult`.
Repository validation, project plist lint and `git diff --check` passed.

Final integrated command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates test
```

The initial restricted
Xcode attempt could not access required package caches; the normal development-signing
build uses the existing cached dependencies. Reviewed ignored AuraFace and web downloader
resources were copied from the main checkout; they are not source changes.

## Remaining evidence

Actual local/network/iCloud volume comparisons, Instruments traces, large-folder interaction
latency and peak-memory measurements remain open. These changes reduce work and isolate
blocking I/O; automated correctness and synthetic slow-read checks do not establish a
measured end-to-end speedup on those volumes. Native UI/device, accessibility, signed release
packaging and the other 3.0 release gates remain separate. The final run retained twelve
Thread Performance Checker reports at the unchanged synchronous Caption draft persistence
bridge (default-priority detached work awaited by a higher-priority caller), plus existing
MDB_MAP_FULL observations. A safe asynchronous/durable-barrier redesign and real-volume
qualification remain follow-up work; this continuation does not claim those warnings are fixed.
