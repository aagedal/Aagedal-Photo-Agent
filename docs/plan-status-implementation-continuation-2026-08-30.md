# Plan-status implementation continuation — 2026-08-30

## Scope and checklist result

This continuation implemented two bounded code-only slices from the 3.0 app-improvement audit and stabilized
the unfiltered test gate under full parallel load. The work advances the broad Phase 3.1 filesystem and
Phase 4.1 state-owner items without satisfying their remaining inventory, measurement, manual, or
architectural exit conditions, so the checklist remains **63 of 75 complete**.

## Structured Keyword import filesystem boundary

The Structured Keywords editor no longer performs `Data(contentsOf:)` from its MainActor import action.
`TextFileImportService` serializes the synchronous read on an actor and returns immutable evidence for a
complete load, cancellation before the reader starts, or cancellation observed after the non-preemptible
read. Only a complete decoded snapshot carries text; cancellation-after-read exposes byte-count evidence but
cannot publish the file contents.

The view owns the import task and a request identity, cancels superseded or disappearing work, and rejects a
late completion before replacing its editable tree. UTF-8, UTF-16, Latin-1, and review-before-Save behavior
are preserved. Five focused characterizations cover off-main execution, pre-cancellation with zero probes,
actor serialization, queued cancellation, post-read cancellation, and the UI source contract. The detailed
record is [Structured Keyword import filesystem validation](structured-keyword-import-filesystem-validation-2026-08-30.md).

## Develop preview-render publication owner

`DevelopPreviewRenderCoordinator` is now the named MainActor owner for the materialized Develop preview,
render-task replacement, request identity, fallback publication, scope publication timing, and image-session
teardown. A replaced, cancelled, or ended request cannot publish late pixels even when its injected renderer
ignores cooperative cancellation. Explicit cancellation retains the last successful preview, while beginning
or ending an image session clears image-scoped output.

`EditWorkspaceView` retains concrete Core Image and Metal render policy. The existing
`DevelopPreviewSessionCoordinator` continues to own source decode, adjacent precache, and full-resolution
upgrade lifetimes; materialized render publication is no longer mixed into that owner. Four new
characterizations cover replacement, image-session teardown, fallback/HDR scope publication, and explicit
cancellation. Together with the adjusted source-session characterizations, the focused preview suites passed
**6 tests in 2 suites** and the broader Develop selection passed **29 tests in 3 suites**.

## Full-suite timing stabilization

The prior unfiltered run recorded 13 short-deadline issues across nine tests in five async coordinator and
filesystem suites while 180 suites competed in parallel. The failures were polling-probe exhaustion rather
than failed behavioral assertions; all five suites passed immediately when selected together.

Seven test-only polling/probe ceilings in `DevelopVersionSessionCoordinatorTests`,
`DevelopComparisonRenderCoordinatorTests`, `AIMaskSelectionCoordinatorTests`,
`DeliveryReceiptLibraryModelTests`, and `RejectMoveServiceTests` now use the existing long-load diagnostic
budget of 30 seconds. This does not add sleeps or slow the success path: the five focused suites still passed
**25 tests in 0.178 seconds**. It prevents a fully occupied test executor from turning scheduler starvation
into a false behavioral failure while retaining a bounded diagnostic failure for a real hang.

The first two unfiltered verification passes exposed the same starvation moving between members of that
seven-probe set. After applying the ceiling consistently, the final unfiltered run passed **1,613 tests in
182 suites** in 38.902 seconds of test time.

## Integrated validation

A clean build of the complete app and unit-test targets succeeded:

```text
xcodebuild build-for-testing -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-v3-session-integration CODE_SIGNING_ALLOWED=NO
** TEST BUILD SUCCEEDED **
```

The combined touched selection then passed **36 tests in 8 suites**:

```text
/private/tmp/aagedal-v3-session-integration/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_01-27-12-+0200.xcresult
```

The final unfiltered result is:

```text
/private/tmp/aagedal-v3-session-integration/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_01-31-09-+0200.xcresult
```

The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature, and SwiftUI
background-publication diagnostics. They did not produce a build failure, test issue, cancellation, or test
failure.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Remaining automatable work includes lower-priority direct
filesystem paths and broader Develop gesture/render/persistence ownership. Manual and external gates still
include protected release-branch configuration, Known People privacy/legal review, real FTP/FTPS/SFTP drills,
accessibility/localization/display validation, slow-volume and Thread Performance Checker evidence,
Instruments RAW/HDR memory benchmarks, and production AuraFace publishing plus supported-macOS validation.
