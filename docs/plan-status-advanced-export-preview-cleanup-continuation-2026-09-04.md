# Plan-status Advanced Export preview cleanup continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Releasing an Advanced Export comparison preview no longer
recursively removes its full-resolution private artifact folder from `AdvancedExportPreviewStorage.deinit`, which
commonly runs while SwiftUI releases state on MainActor. The audit remains at 66 of 75 completed substeps, with
nine remaining.

## Serialized cleanup boundary

`AdvancedExportPreviewCleanupService` now owns preview-folder removal on one serialized actor. Its immutable result
distinguishes cancellation before removal, a durable removal with cancellation observed afterward, and failure.
The synchronous recursive Foundation mutation is sampled on both sides because it cannot be interrupted after it
starts. A privacy-safe signpost records only outcome and cancellation stage; it never records a preview path,
filename, export configuration, or image identity.

`AdvancedExportPreviewStorage.deinit` performs only a non-cancellable asynchronous handoff to that actor. This
preserves best-effort cleanup after the final preview owner disappears without making a MainActor state release wait
for potentially large or slow-volume deletion. Explicit callers retain exact cancellation/commit evidence, while
the lifetime fallback intentionally continues cleanup independently of the cancelled UI task that released it.

## Characterization and validation

Four new characterizations prove that a blocked recursive removal leaves MainActor responsive, actor isolation
serializes a queued cancellation before it reaches the filesystem, cancellation after removal retains durable
commit evidence, an injected removal error returns failure evidence, and final storage release schedules rather than
performs filesystem work. The focused cleanup suite passed all 4 tests. The adjacent Advanced Export pipeline and
cleanup selection passed all 26 tests across two suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project, bundled
component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,973 tests in 229 suites with zero failures in 62.323 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_17-41-18-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
