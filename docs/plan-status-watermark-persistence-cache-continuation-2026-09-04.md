# Plan-status Watermark persistence and cache continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Opening the Watermark library, reading PNG previews from
SwiftUI and Develop, renaming assets, updating default placement, deleting assets, resolving conflicts, and
applying remote changes no longer perform coordinated filesystem work on MainActor. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Serialized library ownership

`WatermarkLibraryPersistenceService` now owns root and item-directory preparation, complete inventory and PNG
reads, tombstone cleanup, conflict resolution, security-scoped imports, metadata commits, and durable deletion on
one actor. Loads return one immutable metadata-and-image snapshot or exact cancellation-prefix evidence. Metadata
and deletion mutations distinguish cancellation before commit from a durable commit that observed cancellation
after its non-preemptible coordinated write.

The shared iCloud routing actor now resolves the selected local/cloud storage root for first load as well as sync
changes, so the initial ubiquity-container lookup also stays off MainActor. Remote events replace the store cache
from one actor-owned snapshot instead of patching metadata and PNG state through separate synchronous reads.

## Cache-only presentation

`WatermarkStore` owns only observable assets, cached PNG bytes, request identity, and recent-write stamps. Its
synchronous `allAssets`, `asset`, `imageData`, and `imageURL` presentation accessors are cache-only and schedule a
load when necessary. Settings explicitly awaits the library load, and Develop begins the load on workspace entry
and requests a fresh preview after publication. Import, rename, default-placement, and delete UI actions now await
the actor boundary; a durable import publishes its already-read PNG bytes without reading the installed file again.

## Characterization and validation

Two new characterizations prove that a complete metadata-and-PNG snapshot is produced off MainActor and that a
pre-cancelled load performs no filesystem access. Source contracts keep coordinated reads, writes, deletion, and
conflict APIs out of the MainActor store and require synchronous PNG presentation to use the published byte cache.

The focused Watermark store/persistence/rendering and iCloud-routing selection passed all 39 tests. The repository
validation gate passed generated documentation, release metadata, JSON, plist/project, bundled component
provenance, logger/investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,977 tests in 229 suites with zero failures in 65.827 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_18-16-09-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
