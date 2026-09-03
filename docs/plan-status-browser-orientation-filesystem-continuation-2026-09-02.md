# Plan-status Browser orientation filesystem continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
real-volume measurement gates. Browser eager orientation loading no longer starts an ad hoc parallel set of XMP
sidecar and ImageIO header reads. Initial folder loading and incremental refresh now use the same serialized
filesystem actor that owns Browser scans and mutations. The audit remains at 66 of 75 completed substeps, with
nine remaining.

## Serialized orientation snapshot

`FileSystemService.displayOrientationSnapshot` reads the frozen URL list as one serialized transaction. XMP
sidecar orientation remains authoritative for RAW/C2PA sidecar-only rotations, with the embedded ImageIO
orientation as fallback. The immutable result carries the request identity, requested count, non-default
orientation map, and either complete status or the exact processed prefix observed at cancellation.

Cancellation is sampled before and after every synchronous per-file read. A read already in progress may finish,
but a cancelled partial snapshot is never presented as complete. The transaction shares the actor used by folder
enumeration, preventing overlapping Browser filesystem reads from interleaving.

## Publication and measurement

`BrowserViewModel` rotates an orientation request identity for every initial-load or refresh request and invalidates
it as soon as a replacement folder load starts. It accepts only complete evidence matching both the request identity
and frozen URL count. The enclosing folder/refresh tasks retain their task-cancellation and current-folder guards,
so an A → B → A navigation cannot publish the first A request's late orientation result.

A privacy-safe `DisplayOrientationSnapshot` signpost records only ready/cancelled state plus processed and requested
aggregate counts. Paths and filenames are not included.

## Characterization and validation

Five new tests prove immutable orientation filtering, off-MainActor execution, pre-read cancellation with no access,
post-read cancellation with exact prefix evidence, serialization against queued folder reads while MainActor stays
responsive, and the Browser request/publication source contract.

The focused `SerializedFileSystemServiceTests` suite passed 24 tests. The adjacent serialized-filesystem,
offline-volume, Browser XMP, sidebar, and full-screen presentation selection passed 39 tests in five suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,927 tests in 225 suites with zero failures in 61.386 seconds. Result
bundle: `build/AagedalPhotoAgent-BrowserOrientation-Final-Verified-2026-09-02.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
