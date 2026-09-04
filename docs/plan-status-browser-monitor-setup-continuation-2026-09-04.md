# Plan-status Browser monitor setup continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Browser FSEvents monitor installation no longer performs a
synchronous directory probe and stream setup from `BrowserAutoRefreshCoordinator` on MainActor. The audit remains
at 66 of 75 completed substeps, with nine remaining.

## Serialized monitor setup boundary

`FolderChangeMonitorService` now serializes the complete directory validation and FSEvents construction on its own
actor. One immutable request captures the folder URL and change callback before crossing that boundary. The result
distinguishes a created monitor, an unavailable monitor, cancellation before setup, and cancellation observed after
the intentionally non-preemptible setup call.

When cancellation arrives after setup, the service stops any newly created stream before returning. A privacy-safe
`OSSignposter` interval records only created, unavailable, or cancellation stage; it does not record a folder path or
filename.

`BrowserAutoRefreshCoordinator` owns a setup task and request identity for each materialized pane. Folder replacement,
pane removal, stop, and teardown cancel pending setup. Publication requires both the current request identity and the
exact current folder URL. If obsolete work nevertheless returns a monitor, the coordinator stops it rather than
installing a stale stream. The existing 30-second actor-backed fallback refresh remains active when FSEvents is
unavailable.

## Characterization and validation

Four new characterizations prove that setup runs away from MainActor, pre-cancellation skips the synchronous factory,
post-setup cancellation is explicit, and the Browser source contract awaits the actor while identity-gating monitor
publication. The focused monitor and metadata-sidecar selection passed all 31 tests across two suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project, bundled
component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,958 tests in 228 suites with zero failures in 64.807 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_11-06-49-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
