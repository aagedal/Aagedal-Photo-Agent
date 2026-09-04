# Plan-status Analysis annotation-index continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Analysis thumbnail and map presentation no longer resolves
each image path's symlinks whenever SwiftUI asks for its saved photo-annotation count. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Published presentation index

`AnalysisWorkspaceModel` now builds an in-memory case index whenever its actor-loaded folder cases, current case,
or presented source URL changes. Persisted cases retain their canonical source identity, while each filename is
also projected onto the already-known Browser presentation folder. This keeps security-scoped or symlinked folder
routes working without repeating a filesystem projection from a synchronous SwiftUI lookup.

The newest case for an identity wins, the open case receives an exact presented-source alias, and index rebuilds
follow case persistence, annotation paste, source replacement, workspace reset, and rename reassociation through
the existing model assignments. `photoAnnotations(for:)` is now a standardized URL dictionary lookup containing
no symlink resolution, resource probe, or `FileManager` access.

## Characterization and validation

Two new characterizations prove that a case loaded through a symlinked presentation folder remains available after
that symlink is removed and that the synchronous source lookup contains no filesystem API. The focused Analysis
case suite passed all 70 tests.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
bundled component provenance, logger/investigation privacy, conflict-marker, and whitespace validation.

The final serial unfiltered run passed all 1,975 tests in 229 suites with zero failures in 65.676 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_17-49-32-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
