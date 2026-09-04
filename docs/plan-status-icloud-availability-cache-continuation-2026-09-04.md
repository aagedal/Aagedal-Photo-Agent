# Plan-status iCloud availability cache continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Opening Sync settings, rendering its footer, and enabling
Preferences sync no longer resolve the app's ubiquity container on MainActor. The audit remains at 66 of 75
completed substeps, with nine remaining.

## Serialized availability boundary

`ICloudAvailabilityProbeService` owns the synchronous ubiquity-container lookup on one serialized actor. Its
immutable result distinguishes available and unavailable outcomes plus cancellation before or after the
non-preemptible Foundation call. A privacy-safe `OSSignposter` interval records only outcome and cancellation
stage; it never records a container path, account value, or preference.

`ICloudSyncCoordinator` owns the cached unknown/checking/available/unavailable state, task, and request identity.
Opening Settings refreshes that cache asynchronously, so SwiftUI body evaluation is filesystem-free. Replaced
probes are cancelled, and only the current request may publish its result.

## Preferences commit gate

Enabling Preferences sync publishes a pending desired state while the availability actor runs. The injected
`PreferencesSyncControlling` boundary is called only when the current probe reports available. Unavailable evidence
clears the pending state, leaves the durable preference disabled, and presents the existing actionable error.
Disabling remains immediate and starts a fresh cache refresh without requiring iCloud to be reachable.

## Characterization and validation

Three new characterizations cover available and unavailable resolution off MainActor, cancellation before and
after the container lookup, and the coordinator's exact Preferences commit/no-commit behavior through injected
availability and preference boundaries. Source contracts reject the former `AppPaths.iCloudDocuments` MainActor
probe and require the Settings refresh plus checking state.

The focused iCloud coordinator suite passed all 24 tests. The adjacent iCloud, metadata-template,
Develop-template, and template-command-routing selection passed all 51 tests across four suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
bundled component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,969 tests in 228 suites with zero failures in 60.183 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_15-46-37-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
