# Plan-status Advanced Export preparation continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Opening Advanced Export no longer synchronously reads RAW
XMP sidecars or probes native image dimensions from `ContentView` on MainActor. Those selection-scaled reads now
run through one serialized actor and return an immutable preparation snapshot. The audit remains at 66 of 75
completed substeps, with nine remaining.

## Serialized preparation boundary

`AdvancedExportPreparationService` accepts immutable inputs containing each selected URL, its live Camera Raw
settings, pending-iCloud state, and EXIF orientation. The actor preserves the established preparation policy while
minimizing filesystem access: live Camera Raw settings take precedence, sidecars are read only for RAW files that
lack live settings, pending iCloud placeholders skip native-dimension probes, and orientations 5 through 8 swap
the reported width and height.

Cancellation is explicit around the synchronous filesystem calls. A pre-cancelled request performs no read, a
cancellation observed during a batch returns the exact prepared prefix, and cancellation during the final
non-preemptible dimension probe distinguishes a complete read from a normally completed request. Actor isolation
also prevents overlapping preparation batches from entering the synchronous access layer concurrently.

`ContentView` snapshots only in-memory selection facts before starting the task. A replacement request cancels and
invalidates the previous request, selection changes cancel pending preparation, and publication requires both the
current request identity and the same current ordered selection. Stale work therefore cannot open Advanced Export
for a superseded selection.

## Characterization and validation

Five new characterizations prove that:

- preparation performs the minimal RAW-sidecar and native-dimension reads away from MainActor while preserving
  live-setting precedence, pending-iCloud behavior, and EXIF orientation;
- mid-batch cancellation reports the exact prepared prefix;
- overlapping preparation batches serialize their synchronous filesystem access;
- pre-read and post-complete-read cancellation remain distinguishable; and
- `ContentView` delegates preparation, owns cancellation, and rejects stale request or selection publication.

Validation completed with:

- the focused Advanced Export suite: 15 tests passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,023 tests in 232 suites passed in 66.069 seconds with zero
  failures.

The full-run result bundle is `Test-Aagedal Photo Agent Tests-2026.09.04_23-38-57-+0200.xcresult` in Xcode
DerivedData. Automated evidence is complete for this bounded continuation, while the remaining manual and
real-volume gates below are deliberately not claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths. The next bounded
candidates include FTP upload preflight sidecar reads and the Known People database cache-miss/reload path; rename,
Compare, and Analysis also retain repeated identity-resolution work. The broad phase still requires real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
