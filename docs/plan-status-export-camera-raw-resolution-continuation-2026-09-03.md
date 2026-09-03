# Plan-status export Camera Raw sidecar-resolution continuation — 2026-09-03

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Local Save, Export, and Archive preparation plus FTP render
and preflight no longer load RAW XMP fallback settings from a MainActor helper. The audit remains at 66 of 75
completed substeps, with nine remaining.

## Serialized resolution boundary

`ExportCameraRawResolutionService` accepts one immutable request containing request identity, ordered image URLs,
and the live workspace settings captured on MainActor. The actor filters that request to RAW images without a live
value, serializes their XMP sidecar reads, and returns the combined live-plus-sidecar settings as immutable evidence.
JPEG and other rendered formats, and RAW files with current in-memory edits, do not touch the sidecar reader.

Cancellation is sampled before the batch and before and after every synchronous, non-preemptible XMP read. Results
distinguish cancellation before any read, after an exact partial prefix, and after the final read; callers install
only a complete request-matched snapshot. A privacy-safe `OSSignposter` interval records only completion state and
aggregate inspected counts, never a filename or path.

`EditExportPipeline.resolveCameraRaw` remains the shared policy facade: it captures live settings on MainActor,
awaits the actor, and overlays only a complete result onto the already-read metadata map. All three ContentView
export paths, FTP rendering, and FTP preflight now await that facade.

## Characterization and validation

Three new characterizations prove that live values win while non-RAW and live RAW inputs avoid filesystem access,
cancellation after a non-preemptible read reports its exact processed prefix, and overlapping MainActor callers run
their sidecar loads off the main thread and serially.

The focused `EditExportPipelineTests` selection passed all 19 tests. The adjacent export/FTP selection passed all
30 tests across `EditExportPipelineTests`, `FTPUploadFileSystemBoundaryTests`, and
`FTPViewModelTransportAcknowledgementTests`.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,943 logical tests in 226 suites with zero failures or skips in
59.741 seconds. Result bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.03_23-05-36-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
