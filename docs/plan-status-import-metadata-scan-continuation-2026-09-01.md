# Plan-status Import metadata-scan continuation — 2026-09-01

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Import capture-date discovery and existing same-date destination-folder discovery no longer
run as ad-hoc detached tasks. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized Import metadata boundaries

`ImportCaptureDateScanService` owns the synchronous SwiftExif and modification-date reads on a serialized actor.
It checks cancellation before and after each non-preemptible read and returns immutable evidence containing the
requested count, exact processed prefix, normalized date groups, source URLs, and capture timestamps. EXIF wall
clock parsing and folder components use a stable POSIX/UTC calendar boundary, while missing EXIF retains the
existing modification-date fallback and files with no date remain in `Unknown Date`.

`ImportFolderSuggestionService` owns the ordered calls to `PreviousImportDetector` for same-date destination
folders. It reports the sorted requested dates, exact completed-date count, and discovered folders as either a
complete or cancelled snapshot. The actor serializes overlapping requests so two destination inventories cannot
probe the filesystem concurrently through this owner.

`ImportViewModel` injects both services and retains task priority, request identity, and presentation state. A
replacement scan, source replacement, or reset cancels and invalidates the old request. Only complete evidence
belonging to the current request may publish; capture groups receive the current import title on the MainActor so
a title entered during a slow scan is preserved. Cancelled work clears the matching progress state without
installing partial evidence.

## Characterization and validation

Eight new tests cover EXIF/modification-date grouping, deterministic folder evidence, both actors' cancellation
after a synchronous read, capture-scan serialization, stale capture and folder-result rejection, and a source
contract that prevents the two Import methods from regaining direct filesystem work or detached tasks.

- Focused and adjacent Import selection: 38 tests in 5 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,883 tests in 221 suites passed in 63.472 seconds.
- Result bundle:
  `/tmp/AagedalPhotoAgent-v3-import-metadata-scan/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_21-30-00-+0200.xcresult`.

The first unfiltered attempt encountered the previously existing timing-sensitive replacement-notice test after
1,091 passing Swift Testing cases. Its complete five-test Develop workspace-session suite then passed in
isolation, and the unmodified serial rerun passed all 1,883 tests. The host also emitted its existing App Intents,
LMDB cache-capacity, background-publication, synthetic-image, thumbnail, XMP, and platform diagnostics; none
failed the authoritative rerun or originated in these Import boundaries.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths and real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates are protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and production AuraFace publishing plus
clean-install/offline/update/rollback/corrupt-download validation.
