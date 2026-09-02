# Plan-status Batch Rename relocation continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Successful Batch Rename publication no longer reconstructs renamed `ImageFile` values by
synchronously reading destination and sidecar resource values from MainActor owners. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Immutable relocation projection

`ImageFile.init(url:relocating:)` changes only path-derived identity (`url`, filename, lowercase filename, and
declared file type) and preserves the immutable file size, modification/addition dates, iCloud state, sidecar
modification token, metadata, edit state, and browser presentation state captured before the rename. It performs
no filesystem reads.

`ContentView`, `BrowserViewModel`, and `AnalysisWorkspaceModel` now use that projection after the serialized Batch
Rename transaction succeeds. This avoids destination `resourceValues` and sidecar probes on the UI executor and
also prevents publication of a mixed snapshot when a slow volume changes between the image and sidecar probes.

The distinct `ImageFile.init(url:copyingFrom:)` path remains in `FileSystemService` for Duplicate. A newly copied
file legitimately needs destination size/date/sidecar facts, and those reads already execute on the serialized
filesystem actor.

## Characterization and validation

Two new tests prove that relocation to a nonexistent destination retains all cached file and presentation facts,
and that the three MainActor rename owners cannot regress to the filesystem-backed copy initializer.

- The focused `BatchRenameSheetStateTests` suite passed its 17 declared tests.
- The integrated Batch Rename sheet/executor, comparison, and analysis-case selection passed its 131 declared
  tests with zero failures.
- `scripts/ci/validate_repository.sh` passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- The first serial unfiltered run completed every correctness test but exceeded the existing 60-second
  `RenamePlanningServiceTests.tenThousandFilePreviewPerformance` tripwire under full-suite host contention. The
  unchanged 10,000-file benchmark passed immediately in isolation. This is recorded as validation noise rather
  than hidden or used to widen its performance budget.
- A follow-up serial run excluding only that separately passing benchmark completed the rest of the suite with
  zero failures in 58.697 seconds. Across the isolated benchmark and follow-up run, every current test has passing
  evidence; there is deliberately no claim that the single unfiltered invocation passed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths and real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
