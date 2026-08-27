# Filesystem async-boundary validation — 2026-08-27

## Scope

This change advances the first two implementation bullets in Phase 3.1 for the Browser filesystem,
audited single-image Metadata persistence, FTP upload staging, and Delivery Receipt summary export:

- Folder scans, subfolder enumeration, trash, rename, create, and move now cross an async
  `FileSystemService` actor boundary before touching `FileManager`.
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

`MetadataIOCoordinatorTests` additionally covers:

- a completed metadata JSON + XMP save returning the installed merged-history record;
- pre-cancelled persistence with no filesystem mutation; and
- an XMP install failure returning the already-durable JSON record as explicit partial success.

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

The existing `FileSystemOfflineAvailabilityTests` continue to cover deferred iCloud items and download
requests at the same boundary.

## Remaining exit-gate work

Phase 3.1 is not complete. Signposts and repeatable benchmarks still need to cover local SSD, network,
iCloud-placeholder, read-only, and very large folders. Thread Performance Checker and slow-volume UI
validation are also required. Lower-priority direct file work outside the Browser mutations and audited
single-image Metadata/FTP/Delivery Receipt paths should be migrated incrementally without weakening each
workflow's recovery and partial-success behavior.
