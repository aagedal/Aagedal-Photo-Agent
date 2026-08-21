# Metadata interoperability boundary-corpus validation

**Date:** 2026-08-20  
**Scope:** journalistic metadata workflow, Phase 0 fixtures and Phase 1 validation

## Implemented behavior

- `legacy-boundaries.json` is a CC0, deterministic recipe corpus covering the UTF-8 byte ceiling
  for all 16 IPTC-IIM text datasets currently dual-written by Photo Agent.
- The corpus includes ASCII and multibyte Unicode boundaries. Limits are checked against
  SwiftExif's dataset definitions rather than copied only into tests.
- Exact-limit values serialize and deserialize through SwiftExif's real IIM writer/reader without
  warnings or truncation. Adding one byte produces one non-fatal compatibility warning and the
  writer still preserves the supplied value.
- The shared validation rule contract now distinguishes character limits from
  `maximumUTF8Bytes`. Repeatable fields such as Keywords are measured item by item.
- A stable built-in `IPTC-IIM Compatibility` profile exposes warning rules for the 16 editable
  legacy mappings. XMP values remain unmodified; the validator reports compatibility risk instead
  of clipping modern metadata.
- The corpus includes date-only, timezone-unknown, UTC, positive and negative half-hour offsets,
  and the `+14:00`/`-12:00` civil-offset edges. Their XMP lexical values and paired IIM 2:55/2:60
  values round-trip without inventing a time or timezone.

## Automated validation

The following focused macOS command passed:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataValidationTests'
```

Result: 24 tests across the two suites passed with no failures. This includes 15 field-boundary
recipes, seven timestamp variants, the portable profile contract, semantic rejection, XMP
preservation, generated embedded-JPEG preservation, editorial-role scalar XMP/IIM round trips,
and XMP/IIM conflict precedence.

## Remaining corpus gate

Phase 0 still requires a confirmed-redistributable IPTC 2025.1 reference image, a decodable
HEIC/HEIF fixture, and representative camera RAW originals, followed by current Adobe Bridge,
Photo Mechanic, and IPTC reference-tool round trips. The later generated CC0 container corpus now
covers TIFF, PNG, JPEG XL, and the authentic RAW/XMP-sidecar safety boundary; it does not substitute
for the remaining licensed fixtures or external-tool checks.
