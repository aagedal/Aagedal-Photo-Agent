# Structured editorial XMP validation

**Date:** 2026-08-20  
**Scope:** journalistic metadata workflow, Phase 1 read/write boundary

## Implemented behavior

- Creator Contact Info maps to the single `Iptc4xmpCore:CreatorContactInfo` structure and preserves
  repeated email, telephone, and web-address values without delimiter-dependent flattening.
- Location Created and Location Shown map to bags of `Iptc4xmpExt:Location` structures. Their
  identifiers remain bags and location names remain language alternatives.
- Latitude and longitude accept decimal values and standard XMP degree/minute direction strings.
  Signed model altitudes serialize as an absolute XMP rational plus `GPSAltitudeRef` and recover
  their sign on read.
- Structured values round-trip through standalone XMP sidecars and embedded JPEG metadata. The
  same authoritative write payload is used by normal saves, rendered exports, and FTP/SFTP
  sidecar preparation.
- The write contract has three states: no structured payload leaves existing values untouched, a
  non-empty payload replaces the modeled values, and an authoritative empty payload clears the
  three structured properties.
- Scalar-only edits preserve the structures byte-semantically where possible. Structured rewrites
  preserve unknown child properties in known structures instead of rebuilding each node solely
  from the modeled fields.

The property names, cardinalities, location child types, and EXIF GPS member types follow the
[IPTC Photo Metadata Standard 2025.1](https://www.iptc.org/std/photometadata/specification/IPTC-PhotoMetadata-2025.1.html).

## Automated validation

The following focused macOS command passed:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests'
```

Result: 10 tests in the interoperability suite passed with no failures. The coverage includes
standards-shaped structured sidecar round trips, two Location Shown entries, embedded-JPEG write
and read, authoritative clear, unknown structured-member preservation, and preservation through an
unrelated scalar edit.

The changed delivery boundary also passed its real-file integration suite:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditExportPipelineTests'
```

Result: all 11 tests passed, including an XMP-sidecar-to-rendered-JPEG assertion for structured
creator contact and created/shown locations. A final combined run of this suite, the 10-test
interoperability suite, `MetadataSidecarServiceTests`, and `MetadataEngineConcurrencyTests` passed
all 58 tests across the four suites.

## Remaining boundary work

The result proves the app's local SwiftExif/XMP boundary for JPEG and standalone XMP; it is not yet
an external interoperability guarantee. Single-image Metadata editing now exposes Creator Contact
Info and Location Created/Shown as structured controls; batch mode refuses implicit structured
mutation and explains the boundary instead of flattening values. The CC0 TIFF, PNG, JPEG XL, and
RAW-sidecar corpus covers local preservation. Current Bridge, Photo Mechanic, IPTC reference-tool,
licensed HEIC/HEIF, and representative camera RAW validation plus manual accessibility review of
the structured editor remain open.
