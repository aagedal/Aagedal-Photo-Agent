# Plan-status Templates iCloud routing continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Enabling or disabling Templates iCloud sync no longer
resolves a security-scoped bookmark, opens or prepares the local folder, resolves the ubiquity container, or
recursively reconciles metadata and Develop templates from `ICloudSyncCoordinator` on MainActor. The audit remains
at 66 of 75 completed substeps, with nine remaining.

## Serialized security-scoped routing boundary

`TemplateICloudRoutingService` now owns local bookmark resolution, the complete lifetime of the resulting security
scope, iCloud-container resolution, and the coordinated preserve-newer merge on one serialized actor. The scope is
released on every unavailable, pre-commit cancellation, durable commit, post-commit cancellation, and thrown-error
path. Immutable results distinguish cancellation before any resolution, cancellation after roots are resolved but
before the non-preemptible commit, unavailable iCloud, and a durable merge that observed cancellation afterward.

`ICloudSyncCoordinator` owns the pending desired state, task, and request identity. A replacement toggle cancels
the old request, and only the current durable result may commit the preference. A privacy-safe `OSSignposter`
interval records only outcome and cancellation stage; it never records a template path, filename, bookmark, or
template value.

## Route publication and cache refresh

The coordinator posts `templatesStorageDidChange` only after both merge and preference commit succeed. Settings and
the main content view reload their metadata and Develop template inventories from that notification, so they no
longer race the asynchronous route change by reading the old store immediately after a toggle.

The `AppPaths` and template-storage release closures are explicitly `@Sendable`, allowing the resolved local scope
to remain actor-owned while preserving the existing balanced-release contract for all template callers.

## Characterization and validation

Three new actor characterizations cover both routing directions, off-main execution, exact security-scope release
counts, unavailable iCloud, pre-commit cancellation, durable post-commit cancellation, and thrown merge errors.
Source contracts cover request-identity publication, removal of the former MainActor merge, and post-commit reload
notification handling in both Settings and the main content view.

The focused iCloud coordinator suite passed all 21 tests. The adjacent iCloud, metadata-template, Develop-template,
and template-command-routing selection passed all 48 tests across four suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project, bundled
component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,966 tests in 228 suites with zero failures in 62.039 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_15-04-49-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
