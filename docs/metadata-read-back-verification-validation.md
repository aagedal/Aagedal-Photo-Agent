# Metadata read-back verification validation

**Validated:** 2026-08-21  
**Standard baseline:** IPTC Photo Metadata Standard 2025.1

## Implemented contract

- `IPTCMetadataVerifier` is a pure, non-UI, `Sendable` boundary that compares selected writable
  fields and returns stable field identity, the applied rule, and canonical expected/actual values.
- Scalar comparison normalizes CRLF/CR line endings, Unicode canonical composition, boundary
  whitespace, and empty-as-absent without hiding internal text edits.
- XMP Bag-like values ignore order, duplicates, and empty entries. Ordered contact address lines
  remain order-sensitive.
- Digital Source Type and Scene Code aliases normalize to their IPTC NewsCodes representation.
- Date comparison retains day/minute/second/fraction precision and whether timezone is known while
  accepting different offsets that represent the same instant.
- GPS latitude/longitude compare at the writer's six-decimal precision; structured location
  altitude compares at three decimals.
- Creator Contact Info and Location Created/Shown compare recursively, with explicit ordered versus
  unordered collection semantics.
- `SwiftExifReadService.verifyReadBack` rereads completed output through the production parser and
  returns the same structured report.

## Test evidence

The focused suite covers scalar normalization, Bag semantics, URI/QCode aliases, date precision and
timezone projections, coordinate precision, structured contact/location rules, writable-field
selection, and a real SwiftExif embedded JPEG write/read/verify cycle.

Command:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-verification-tests-01' \
  -only-testing:'Agedal Photo Agent Tests/IPTCMetadataVerificationTests'
```

Result: **8 tests passed**.

## Remaining integration

- Use the report to gate staged Deadline Mode delivery and surface actionable differences.
- Verify RAW descriptive writes by reading the resulting XMP sidecar boundary.
- Preserve and compare non-default language alternatives once the metadata model exposes them.
- Extend comparison rules alongside each newly modeled editorial field.
