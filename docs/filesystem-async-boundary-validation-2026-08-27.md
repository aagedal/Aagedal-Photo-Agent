# Filesystem async-boundary validation — 2026-08-27

## Scope

This change addresses the first two implementation bullets in Phase 3.1 for the browser folder tree:

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

## Automated coverage

`SerializedFileSystemServiceTests` covers:

- immutable create/rename/move commit results;
- sorted folder-only enumeration;
- pre-cancelled mutation with zero filesystem changes;
- destination collision with both source and destination preserved;
- batch-trash partial success and pre-cancellation;
- image move with XMP and editorial sidecars; and
- unique-name duplication with its editorial sidecar.

The existing `FileSystemOfflineAvailabilityTests` continue to cover deferred iCloud items and download
requests at the same boundary.

## Remaining exit-gate work

Phase 3.1 is not complete. Signposts and repeatable benchmarks still need to cover local SSD, network,
iCloud-placeholder, read-only, and very large folders. Thread Performance Checker and slow-volume UI
validation are also required. Remaining direct file work outside this bounded browser mutation slice should
be migrated incrementally without weakening each workflow's recovery and partial-success behavior.
