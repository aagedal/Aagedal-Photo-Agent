# Plan-status Known People iCloud routing continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Enabling or disabling Known People iCloud sync no longer
resolves the ubiquity container and recursively reconciles the database from `ICloudSyncCoordinator` on MainActor.
The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized routing boundary

`KnownPeopleICloudRoutingService` now serializes local/cloud root resolution and the complete coordinated
preserve-newer merge on its own actor. Immutable results distinguish unavailable iCloud, cancellation before
resolution, cancellation before the recursive commit, and a durable merge that observed cancellation after its
intentionally non-preemptible filesystem transaction. A privacy-safe signpost records only the outcome and
cancellation stage.

`ICloudSyncCoordinator` owns the pending desired state, task, and request identity. A replaced request is cancelled,
and only the current result may commit the routing preference, Known People cache route, first-enable privacy
confirmation, or cloud watcher. The already-resolved destination is passed into `KnownPeopleService`, avoiding a
second MainActor ubiquity lookup when the cache reload begins.

## Cloud watcher and Settings integration

The Known People metadata-query watcher now resolves and prepares its startup root through the same actor, caches
that root for notification filtering, and accepts the proven cloud root directly after a successful enable. It no
longer probes `AppPaths.iCloudKnownPeopleURL` or creates the monitored root on MainActor.

Settings storage summaries await any active route transaction and resolve their storage URL through the actor before
the existing serialized byte-count scan begins. Request identity still prevents a late summary from replacing the
current toggle state.

## Characterization and validation

Three new actor characterizations cover enable/disable direction, off-main execution, unavailable iCloud, and the
distinction between pre-commit cancellation and durable post-commit cancellation. Source contracts cover
request-identity publication, resolved-route cache installation, routing completion before storage-summary capture,
and removal of the former MainActor merge/probe paths.

The focused iCloud coordinator suite passed all 16 tests. The adjacent iCloud, Known People, face-embedding, and
startup-signpost selection passed all 52 tests across four suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project, bundled
component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,961 tests in 228 suites with zero failures in 65.417 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_11-58-47-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
