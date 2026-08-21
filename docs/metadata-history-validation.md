# Metadata history validation

**Validated:** 2026-08-21  
**Scope:** Phase 1 stable identity, readable display, privacy, migration, and restore safety

## Implemented contract

- New history entries retain `MetadataFieldID` while preserving the legacy `fieldName` payload and
  decoding label-only sidecars written before stable IDs were stored.
- Repeatable metadata is stored as a JSON array for lossless replay, including individual values
  containing commas. Legacy comma-delimited entries remain readable and restorable.
- Display values translate controlled canonical values such as Digital Source Type, Scene Code,
  urgency, country code, rating, and color label without changing their stored representation.
- Long narrative fields are summarized. GUID/job/supplier identifiers, contact information,
  structured locations, and GPS values are redacted or represented only by presence state.
- Summarized/redacted history is deliberately non-restorable. Restore also rejects unknown legacy
  events instead of reporting a successful no-op.
- Browser metadata review and face-recognition updates use the same lossless history boundary.

## Test evidence

The focused run covers new and legacy decoding, stable identity, display labels, privacy policies,
structured metadata coverage, exact and refused restores, comma-bearing arrays, and existing
sidecar behavior.

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-history-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataHistoryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataSidecarServiceTests'
```

Result: **34 tests passed**.

## Remaining integration

- Preserve this fail-closed policy when future structured fields become directly restorable.
- Add newly introduced metadata fields to `MetadataFieldID` or an explicitly typed structured
  history representation rather than returning to display-name dispatch.
- Keep history limits and retention behavior under review as sidecar records grow.
