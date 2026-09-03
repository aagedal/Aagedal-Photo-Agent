# Plan-status path-containment and cached-identity continuation — 2026-09-03

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Import destination safety checks and Browser folder-rename
containment no longer walk existing ancestors or resolve symlinks from MainActor owners. Import's voice-memo UI
projection also no longer repeats source canonicalization from computed properties. The audit remains at 66 of 75
completed substeps, with nine remaining.

## Serialized containment evidence

`SafePathContainmentService` accepts one immutable request containing request identity, root, and candidate paths.
Its actor serializes the existing symlink-aware containment algorithm and returns immutable complete evidence or an
exact checked prefix when cancellation is observed. Cancellation is sampled before and after every synchronous,
non-preemptible projection. A privacy-safe signpost records only result state and aggregate checked counts; it never
records a path or filename.

Import batches every primary destination through this boundary before bundle collision planning and batches the
resolved voice-memo destinations before constructing copy jobs. It accepts only request-matched, complete evidence
covering the entire candidate batch. Browser folder rename now awaits the same boundary before asking the serialized
filesystem actor to mutate the folder.

## Cached voice-memo source identity

`ImportVoiceMemoAssociationScanService` now returns the source-to-canonical image URL map it captured on its
filesystem actor along with the complete association report. `ImportViewModel` publishes and invalidates that map
with the report, then uses pure in-memory lookups for dual-source deduplication, selected-association filtering, and
initial import-job projection. This removes repeated `resolvingSymlinksInPath()` work from frequently evaluated
MainActor properties while preserving symlink-canonical association identity.

## Characterization and validation

Four new characterizations prove that containment runs away from MainActor, stops at the first escaping candidate,
a pre-cancelled request performs no projection, cancellation after a non-preemptible projection reports the exact
uncommitted prefix, and the Import/Browser owners use the actor boundary. The voice-memo association suite also
verifies the immutable canonical source map. The focused two-suite selection passed all 12 tests, and the adjacent
Import/Browser regression selection passed.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,940 logical tests in 226 suites, representing 2,067 expanded
device/configuration executions, with zero failures or skips in 63.425 seconds. Result bundle:
`build/AagedalPhotoAgent-PathContainment-2026-09-03.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
