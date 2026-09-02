# Plan-status Face scan signature continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Incremental face-scan classification and the file signature captured after each successful
detection now cross one shared serialized actor instead of reading file attributes from scan orchestration. The
audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized signature boundary

`FaceScanFileSignatureService` owns every image attribute read used by incremental face scanning. Initial
classification returns one immutable snapshot containing the ordered images to scan, removed-or-modified paths,
and unchanged paths. The actor is injectable for deterministic blocked-volume, cancellation, and executor tests.

Cancellation is sampled before and after every non-preemptible Foundation attribute read. A cancelled
classification reports the exact processed/requested counts and publishes no partial path sets; the view model
retains its last complete face snapshot and persists it as an incomplete scan rather than deleting faces from
uninspected files. A per-image signature read separately reports cancellation before access versus after the
attribute read. Cancelled or unreadable signatures are not installed, leaving those images eligible for the next
incremental scan.

The same actor handles classification and post-detection capture, preventing the two paths from overlapping a
slow volume probe. `FileSignature` is now explicitly `Sendable`, and the old free attribute-reader and
classification helpers have been removed from `FaceRecognitionViewModel`.

## Characterization and validation

Four new tests prove that:

- classification returns the correct complete immutable path sets away from MainActor;
- cancellation after a blocked attribute read reports the exact one-of-two processed prefix;
- initial classification and post-detection signature capture cannot overlap; and
- both view-model paths await the injected actor and contain no direct attribute read.

The focused signature and adjacent folder-load selection passed 17 tests in two suites. The final serial
unfiltered run passed all 1,914 tests in 224 suites with zero failures in 62.759 seconds. Result bundle:
`build/AagedalPhotoAgent-FaceSignatures-2026-09-02.xcresult`.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, privacy, conflict-marker, and whitespace checks.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
