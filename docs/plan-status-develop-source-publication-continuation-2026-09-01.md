# Plan-status Develop source-publication continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by closing the retained source-pixel
ownership gap in the existing Develop preview session. It does not complete the broad Phase 4.1 extraction gate,
so the audit remains at 63 of 75 completed substeps.

## Source publication ownership

`DevelopPreviewSessionCoordinator` now owns the quick/fallback `NSImage` and retained `CIImage` together with
their image URL, loaded orientation, session generation, loading progress, and the source-load, adjacent-precache,
and full-resolution-upgrade tasks. `EditWorkspaceView` reads both representations through coordinator-backed
aliases and no longer declares or directly assigns independent source-pixel state.

Every asynchronous decode publication carries the image URL and captured session generation:

- quick embedded RAW previews, non-RAW previews, and thumbnail fallbacks replace both representations atomically;
- final RAW/non-RAW materialization replaces only the retained `CIImage`, preserving the quick `NSImage` fallback;
- A → B → A navigation rejects the first A session's late result even though the URL matches again;
- in-memory orientation changes replace both representations and the loaded orientation through one image-scoped
  operation; and
- image replacement or workspace teardown clears retained pixels at the same boundary that cancels producer work
  and resets progress.

Decode execution and Metal texture upload remain injected at the existing view/pipeline boundary. This slice
therefore makes source publication independently testable without claiming ownership of the remaining decode,
render-policy, or Metal-publication work.

## Characterization and validation

Three new characterizations cover stale-generation rejection, image-scoped materialization and rotation, teardown
cleanup, and the view's removal of independent `@State` source storage. The existing two preview-session tests
continue to cover task cancellation, progress reset, source identity, and orientation lifetime.

- Focused `DevelopPreviewSessionCoordinatorTests`: 5 tests passed.
- Adjacent interaction, preview-render, interactive-render, and comparison-render regression: 36 tests in
  4 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,841 tests in 215 suites passed in 60.612 seconds.
- Result bundle: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_15-38-32-+0200.xcresult`.

The test host also emitted its existing App Intents/iCloud entitlement, LMDB cache-capacity, and AppKit monitor-
token warnings; none failed the test gate or originated in this source-publication change.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs broader decode-execution, render-policy, Metal-texture
publication, geometry, and view-decomposition ownership before the major-feature exit gate can be claimed. Phase
3.1 also remains open for lower-priority direct filesystem paths plus local SSD, network, iCloud-placeholder,
read-only, large-library, signpost, and Thread Performance Checker evidence.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
