# Plan-status export artifact-finalization continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Post-render RAW sidecar copying, incomplete-archive
compensation, and the Finder-visibility postcondition no longer return to a MainActor caller after the detached
renderer completes. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized finalization boundary

`ExportArtifactFinalizationService` receives an immutable request containing request identity, source and rendered
artifact identities, and whether the output is a RAW archive whose XMP sidecar must be finalized. Its actor serializes
the existing sidecar copy, fail-closed removal of pixels when sidecar finalization fails, hidden-file inspection, and
visibility repair. DNG, local Save/Export, RAW archive, and FTP JPEG rendering all cross the same boundary through
`EditExportPipeline.renderItem`.

Finalization is intentionally non-preemptible once submitted. A rendered RAW archive must not be published without
its authoritative edit sidecar merely because cancellation arrived between the render and sidecar copy, and every
user-facing artifact still receives the visibility postcondition. Immutable evidence records the completed sidecar
step, whether visibility was repaired, and cancellation observed before and after finalization. Sidecar failure keeps
the established best-effort compensation behavior and returns the original error after attempting to remove the
incomplete rendered pixels.

A privacy-safe `OSSignposter` interval records only complete, sidecar-failed, or visibility-failed state and Boolean
archive/visibility facts. It never records a path or filename.

## Characterization and validation

Three new characterizations prove that overlapping MainActor callers finalize serially away from the main thread,
RAW sidecar failure attempts compensating removal before visibility publication, and cancellation during a
non-preemptible sidecar step does not skip the remaining durable postcondition and is reported in the returned
evidence. The existing real-file visibility characterization now awaits the same production service.

The focused `EditExportPipelineTests` suite passed all 22 tests. The adjacent export, RAW archive, FTP filesystem,
and FTP transport-acknowledgement selection passed all 53 tests across four suites.

The final serial unfiltered run passed all 1,950 logical tests in 227 suites with zero failures or skips in
61.686 seconds. Result bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_09-03-22-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
