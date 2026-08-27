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

## Automated coverage

`SerializedFileSystemServiceTests` covers:

- immutable create/rename/move commit results;
- sorted folder-only enumeration;
- pre-cancelled mutation with zero filesystem changes; and
- destination collision with both source and destination preserved.

The existing `FileSystemOfflineAvailabilityTests` continue to cover deferred iCloud items and download
requests at the same boundary.

## Remaining exit-gate work

Phase 3.1 is not complete. Signposts and repeatable benchmarks still need to cover local SSD, network,
iCloud-placeholder, read-only, and very large folders. Thread Performance Checker and slow-volume UI
validation are also required, and other browser workflows (such as batch image trash/duplicate) still have
separate filesystem paths that should be migrated incrementally without weakening their current partial-
success behavior.
