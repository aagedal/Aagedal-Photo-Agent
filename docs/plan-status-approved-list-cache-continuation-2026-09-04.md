# Plan-status Approved List cache continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Approved Keywords initialization, notification refresh,
legacy save, and deletion no longer synchronously read or remove the managed list through the MainActor store.
The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized cache and mutation boundary

`ApprovedListService` now reuses `KeywordListEditorPersistenceService` for managed-list loads, saves, and deletes.
Initial loading and anonymous editor, migration, routing, or remote-change notifications await immutable actor
results while all synchronous Settings and validation accessors read only the published parsed cache.

Each load owns a request identity and cancellable task. A replacement request invalidates its predecessor, and only
the current complete matching URL snapshot may update observable state. Missing files publish an explicit empty
configuration; partial or cancelled reads preserve the last complete cache. Imports and saves install their exact
durable entry evidence without a second disk read. Deletion publishes only after the actor reports the destination
missing or durably removed, including removal followed immediately by cancellation.

Notification ownership is explicit: identified writers publish their own immutable result and do not trigger
another service instance to reread shared test or process state. Anonymous notifications still schedule a serialized
refresh, preserving editor, migration, storage-routing, and remote-update behavior.

## Characterization and validation

Two new characterizations prove that a MainActor cache owner receives normalized actor-loaded entries without any
filesystem access on the main thread, and that production cache, save, delete, and Settings call sites no longer use
the synchronous `KeywordListsStore` persistence surface.

Validation completed with:

- the focused Approved List cache and keyword-list persistence selection: 22 tests in two suites passed;
- the broader Approved List and keyword-list regression selection: 56 tests in eight suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 1,984 tests in 229 suites passed in 72.243 seconds.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_20-22-12-+0200.xcresult` in Xcode DerivedData. Automated evidence is
complete for this bounded continuation; the remaining manual and real-volume gates below are deliberately not
claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem/cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
