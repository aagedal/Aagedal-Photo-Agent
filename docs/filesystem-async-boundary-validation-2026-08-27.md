# Filesystem async-boundary validation — 2026-08-27

## Scope

This change advances the first two implementation bullets in Phase 3.1 for the Browser filesystem,
audited single-image Metadata persistence, FTP upload staging, and Delivery Receipt summary export:

- Folder scans, subfolder enumeration, trash, rename, create, and move now cross an async
  `FileSystemService` actor boundary before touching `FileManager`.
- Primary and secondary-card import source discovery now cross a serialized
  `ImportSourceDiscoveryService` actor boundary. Recursive enumeration filters to regular files, skips
  hidden/package descendants, checks cancellation for each item, emits privacy-safe ready/cancelled/failed
  signposts, and returns explicit enumeration failures instead of silently treating an unreadable source as
  empty. Main-actor consumers reject stale results when the selected source changes. Discovery also publishes
  immutable progress snapshots at a five-second production cadence so the Import window can show an active
  scan and live regular-file, supported-image, and WAV counts without enumerating on the main actor.
- The actor serializes these potentially blocking operations, while the observable browser model only
  consumes immutable `Sendable` scan/mutation results on the main actor.
- Cancellation is checked before enumeration and mutation, and periodically during large enumerations.
  A synchronous Foundation mutation that has already committed returns a result even if cancellation was
  requested during the call, so the browser cannot report cancellation while disk has actually changed.
- Destination collisions are checked inside the serialized transaction. They return a typed error without
  changing either source or destination, making the no-partial-success case explicit.
- Batch image trash, image moves, move-to-new-subfolder, and duplication now use the same actor. Their
  immutable results distinguish committed primary files, companion-sidecar failures, and cancellation that
  stopped unstarted items. Main-actor browser state is reconciled only from those results.
- Moving rejected image bundles now crosses that actor as well. Cancellation is observed before destination
  creation and between complete image/XMP/editorial-sidecar bundles, so an in-progress bundle still commits
  or rolls back transactionally. The browser snapshots the source folder before awaiting and rejects a stale
  completion if the user navigated elsewhere, preventing slow-volume work from reopening the old folder.
- Existing move behavior for adjacent XMP and editorial JSON sidecars is preserved. Duplication retains its
  existing editorial JSON-sidecar copy behavior, including reporting a sidecar failure separately from a
  successfully-created primary duplicate.
- The single-image Metadata save that installs JSON history and mirrors it into XMP now crosses one actor
  boundary. Its immutable result distinguishes full completion, cancellation before either write, and the
  durable partial-success case where merged JSON history committed but the XMP mirror failed or was skipped
  after cancellation. MetadataViewModel advances its history baseline from a committed partial result so a
  retry cannot manufacture duplicate history entries.
- FTP upload history file scans, temporary-workspace creation/cleanup, duplicate-name hard-link/copy staging,
  persistent `Uploaded`-folder creation, and rendered-file sequencing now cross a serialized
  `FTPUploadFileSystemBoundary`. The main actor consumes immutable inventory/commit evidence, cancellation is
  checked before scans and mutations, and staging/sequencing results record cancellation arriving after their
  synchronous commit instead of misreporting the on-disk state.
- Delivery Receipt's privacy-preserving summary export now performs its exclusive-create write through the
  shared serialized `DeliveryReceiptSummaryExportBoundary`. A pre-cancelled export returns without creating
  the destination; a completed write returns immutable destination/byte-count evidence and records
  cancellation that arrived after the synchronous commit. Existing destinations remain untouched.

## Automated coverage

`SerializedFileSystemServiceTests` covers:

- immutable create/rename/move commit results;
- sorted folder-only enumeration;
- pre-cancelled mutation with zero filesystem changes;
- destination collision with both source and destination preserved;
- batch-trash partial success and pre-cancellation;
- image move with XMP and editorial sidecars; and
- unique-name duplication with its editorial sidecar.

`RejectMoveServiceTests` additionally covers:

- collision-safe association of an image with both sidecar formats through the actor boundary;
- transactional rollback after a sidecar move failure;
- pre-cancellation with no `.Rejected` directory or other filesystem mutation; and
- deterministic cancellation between two bundles, preserving the first complete commit and leaving the
  unstarted second bundle at its source; and
- stale completion from a previous folder leaving the browser's new folder selection intact.

`MetadataIOCoordinatorTests` additionally covers:

- a completed metadata JSON + XMP save returning the installed merged-history record;
- pre-cancelled persistence with no filesystem mutation; and
- an XMP install failure returning the already-durable JSON record as explicit partial success.

`ImportSourceDiscoveryServiceTests` additionally covers:

- recursive regular-file discovery while skipping hidden files and package descendants; and
- pre-I/O cancellation surfacing `CancellationError` without touching the source;
- the five-second production progress cadence; and
- exact final progress counts for regular files, supported images, and WAV files.

`ImportPreflightServiceTests` and `ImportViewModelTests` additionally cover:

- duplicate image/voice-memo skip propagation and immutable primary/backup collision evidence;
- serialized overlapping preflights and pre-cancellation before any filesystem probe; and
- reset invalidating a late preflight publication without creating a destination.

`FTPUploadFileSystemBoundaryTests` additionally covers:

- ordered immutable file inventory with missing-file fallback facts;
- source-preserving duplicate-name staging;
- rendered-file sequencing across both on-disk and in-batch collisions; and
- pre-cancelled sequencing with zero filesystem mutation.

`DeliveryReceiptLibraryModelTests` additionally covers:

- privacy-safe summary export with exclusive-create/no-overwrite behavior;
- pre-cancellation leaving no destination and producing a typed model error; and
- immutable destination/byte-count commit evidence from the serialized writer.

Focused verification on 2026-08-27 passed all four tests in that suite with `** TEST SUCCEEDED **`. A clean
integration build also compiled the app and all test targets, and the four FTP boundary tests passed within
the 1,544-test run. Six unrelated coordinator timing assertions failed only under the fully parallel run;
their two focused suites then passed all six tests against the same build.

Focused Delivery Receipt verification on 2026-08-27 passed all eight Activity-library tests, including the
pre-cancellation/no-mutation and immutable commit-evidence cases, with `** TEST SUCCEEDED **`.

Focused import-source discovery verification on 2026-08-29 passed all four tests after the progress follow-up,
including a complete application/test-target compile, with `** TEST SUCCEEDED **`.

Focused rejected-move and command-router verification on 2026-08-29 compiled the current application and
test targets and passed all **13 tests in 2 suites** (four rejected-move tests and nine router tests) with
`** TEST SUCCEEDED **`. The result bundle is:

```text
/tmp/aagedal-reject-boundary-20260829-1548/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-46-01-+0200.xcresult
```

Manual slow-volume, navigation-during-move, failure-presentation, and Thread Performance Checker validation
is still required before this rejected-file slice enters a release candidate. Repeat the slow-volume check
on every supported macOS tier before marking the broader Phase 3.1 exit gate complete. The exact procedure
is listed under **Manual validation still required** in
[`plan-status-follow-up-validation-2026-08-29.md`](plan-status-follow-up-validation-2026-08-29.md).

The 2026-08-29 integrated continuation then completed a full `build-for-testing` and passed all **34 tests
in 4 focused suites**: `AppCommandRouterTests`, `RejectMoveServiceTests`, `ImportPreflightServiceTests`, and
`ImportViewModelTests`. The action status was `succeeded`; the preserved result bundle is:

```text
/private/tmp/aagedal-focused-20260829-172219.xcresult
```

The existing `FileSystemOfflineAvailabilityTests` continue to cover deferred iCloud items and download
requests at the same boundary.

The 2026-08-29 face-group follow-up moved optional source-photo trash out of
`FaceRecognitionViewModel.deleteGroup` and through the same serialized actor. Its immutable result records
committed URLs, per-item failures, cancellation, and whether face-data mutation was applied or rejected as
stale. Three focused characterizations cover partial failure off the main actor, stale completion preserving
replacement state, and pre-cancellation with zero mutation. All three passed both in isolation and in the
combined 30-test run at `/private/tmp/aagedal-v3-plan-20260829.xcresult`.

## Remaining exit-gate work

Phase 3.1 is not complete. Signposts and repeatable benchmarks still need to cover local SSD, network,
iCloud-placeholder, read-only, and very large folders. Thread Performance Checker and slow-volume UI
validation are also required. Lower-priority direct file work outside the Browser mutations and audited
single-image Metadata/FTP/Delivery Receipt paths should be migrated incrementally without weakening each
workflow's recovery and partial-success behavior.
