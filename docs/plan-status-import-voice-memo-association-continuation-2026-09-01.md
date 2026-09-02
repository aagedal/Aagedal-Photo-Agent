# Plan-status Import voice-memo association continuation — 2026-09-01

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Import's Sony dual-card voice-memo association no longer performs synchronous EXIF and file-date
reads in an ad-hoc detached task. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized association boundary

`ImportVoiceMemoAssociationScanService` owns primary-image EXIF reads, primary/companion WAV resource-date reads,
companion-image EXIF reads, security-scoped access, and final deterministic association on one injected actor. It
samples cancellation before and after every non-preemptible read. Complete results contain an immutable association
report and exact requested/processed counts; cancellation returns the exact processed prefix and cannot be presented
as complete evidence.

`ImportViewModel` now owns only task priority, request identity, source snapshots, presentation state, and publication.
Starting a replacement source scan, refreshing associations, clearing the companion source, resetting, or teardown
cancels and invalidates prior work. Only a complete result carrying the current request identity may replace the
visible association report, including when two requests use otherwise equal source arrays.

## Characterization and validation

Five new tests cover a complete association report, cancellation immediately after a blocked image read, serialized
overlapping scans, stale-result rejection in `ImportViewModel`, and a source contract that prevents EXIF/resource reads
or detached-task ownership from returning to the view model.

- Adjacent Import/voice-memo selection: 37 tests passed with zero failures.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project, provenance,
  privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,888 logical tests (2,015 expanded test runs) passed with zero failures in 62.624
  seconds.
- Result bundle:
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_22-03-27-+0200.xcresult`.

The initial focused compile exposed a Swift restriction on covariant `Self` in default argument expressions. The
defaults now name the concrete actor type; the authoritative focused, adjacent, and serial unfiltered reruns passed.
The host emitted only the existing AppKit monitor optional-coercion warnings during the initial rebuild.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths and real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
