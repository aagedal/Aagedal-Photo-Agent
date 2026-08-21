# RAW descriptive write boundary validation

**Validated:** 2026-08-21  
**Scope:** Phase 1 proprietary RAW target safety and XMP preservation

## Implemented contract

- `DescriptiveMetadataWriteTargetResolver` coerces embedded and dual-write requests for every
  supported proprietary RAW extension to one adjacent XMP target. History-only remains
  non-mutating.
- The RAW Settings picker exposes only history-only and XMP choices, and a previously persisted
  embedded RAW choice is normalized to XMP when resolved or loaded.
- `DescriptiveMetadataWriteBoundary` is non-UI and `Sendable`; callers choose explicit merge or
  authoritative replace semantics.
- Descriptive sidecar writes preserve existing Camera Raw settings and supported unmodeled
  CRS/Lightroom XMP while replace can explicitly clear omitted descriptive properties.
- An optional exact-byte XMP snapshot rejects a delayed write after another process changes the
  sidecar. Cancellation is checked before any target mutation.
- The explicit write-and-clear-history path and multi-image reverse-geocode path now use this
  boundary for RAW instead of treating SwiftExif's embedded-RAW refusal as a successful write.

## Test evidence

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-raw-boundary-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveMetadataWriteBoundaryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataWriteModePresetTests'
```

Result: **10 tests passed**: five boundary tests and five preset-resolution tests. The real-file
regression verifies that RAW source bytes are identical before and after the operation while the
adjacent XMP reflects the descriptive update.

## Remaining integration

- Route any future descriptive write entry point through the same resolver rather than calling an
  embedded writer directly.
- Add normalized read-back verification of the resulting RAW XMP to the future delivery preflight.
- Extend explicit per-field operations beyond whole-record merge/replace to cover append, clear,
  and untouched semantics throughout batch editing.
