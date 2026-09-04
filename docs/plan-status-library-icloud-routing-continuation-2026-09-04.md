# Plan-status Teams and Watermark iCloud routing continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Enabling or disabling Teams and Watermark iCloud sync no
longer resolves the ubiquity container or recursively reconciles either library from `ICloudSyncCoordinator` on
MainActor. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized library routing

`LibraryICloudRoutingService` now provides independently serialized Teams and Watermark instances. Each instance
resolves its local/cloud roots and performs the complete coordinated preserve-newer merge on its actor. Immutable
results distinguish unavailable iCloud, cancellation before resolution, cancellation before the recursive commit,
and a durable merge that observed cancellation after its intentionally non-preemptible filesystem transaction. A
privacy-safe signpost records only the outcome and cancellation stage.

`ICloudSyncCoordinator` now owns a pending desired state, task, and request identity for each library. Replaced
requests are cancelled, and only the current result may commit the preference, install the resolved store route,
reload the library, or start its cloud watcher. Failed and cancelled operations clear pending presentation without
publishing an unproven preference.

## Store and watcher handoff

Successful routing passes the already-proven destination into `RosterStore` and `WatermarkStore`, avoiding an
immediate second MainActor ubiquity-container lookup while each store invalidates and reloads its cache.

Both metadata-query watchers resolve and prepare their startup roots through their corresponding actor instance,
cache the resolved root for notification filtering, and accept the proven cloud root directly after a successful
enable. They no longer probe `AppPaths.iCloudTeamsURL` or `AppPaths.iCloudWatermarksURL`, or create the monitored
root, on MainActor.

## Characterization and validation

Two new actor characterizations cover both routing directions, off-main execution, unavailable iCloud, and durable
post-commit cancellation. Source contracts cover request-identity publication, resolved-route cache installation,
removal of the former MainActor merges, and removal of direct iCloud probes from both watchers.

The focused iCloud coordinator suite passed all 18 tests. The adjacent iCloud, RosterStore, WatermarkStore, and app
startup signpost selection passed all 30 tests across four suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project, bundled
component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,963 tests in 228 suites with zero failures in 68.777 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_14-52-02-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the security-scoped Templates iCloud route, remaining lower-priority direct filesystem and
cached-model paths, and real local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library,
signpost, and Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR Instruments
benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
