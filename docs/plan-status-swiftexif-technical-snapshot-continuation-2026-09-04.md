# Plan-status SwiftExif technical snapshot continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. The SwiftExif technical-metadata enrichment path no longer
performs its optional native ImageIO header read after returning to a MainActor owner. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Complete per-photo snapshot boundary

`SwiftExifReadService.readTechnicalMetadata` now returns a `TechnicalMetadata` value assembled inside the existing
per-photo `MetadataIOCoordinator` operation. SwiftExif parsing and the optional container profile/bit-depth read
therefore execute away from MainActor and under the same serialization lock. A metadata write cannot begin after
the embedded metadata read but before the native header read, so the caller receives one coherent immutable
snapshot rather than facts assembled across two independently timed source states.

The lightweight `includeNativeImageInfo: false` enrichment used after the technical inspector's fast ImageIO pass
still skips the second header read. Analysis and any other full-enrichment callers now receive the complete value
without performing filesystem-capable assembly after their await. The injectable snapshot builder keeps that
executor boundary directly testable without changing production parsing or merge policy.

## Characterization and validation

Three new characterizations prove that complete snapshot assembly runs away from MainActor, that native enrichment
receives the selected image URL while the no-native path receives no URL, and that the public read method delegates
to the complete serialized snapshot boundary instead of reconstructing from a returned generic dictionary.

Validation completed with:

- the focused SwiftExif technical-metadata snapshot suite: 3 tests passed;
- the adjacent Technical Metadata, metadata-concurrency, and Analysis selection: 118 logical tests with 123 expanded
  executions passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,000 logical tests with 2,127 expanded executions passed in
  64.701 seconds, with zero failures or skips.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_22-02-27-+0200.xcresult` in Xcode DerivedData. Automated evidence is
complete for this bounded continuation, while the remaining manual and real-volume gates below are deliberately not
claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
