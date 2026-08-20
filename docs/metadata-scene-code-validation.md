# Scene Code validation

**Date:** 2026-08-21  
**Standard:** IPTC Photo Metadata Standard 2025.1  
**Field:** Scene (`Iptc4xmpCore:Scene`)

## Implemented contract

- `IPTCMetadata.sceneCodes` stores ordered, deduplicated six-digit codes independently of the
  human-readable vocabulary labels shown by editors.
- The selectable vocabulary is a frozen snapshot of the 24 current IPTC Scene NewsCodes used by
  the 2025.1 editorial baseline.
- Plain six-digit codes, the IPTC Scene HTTP/HTTPS URI forms, and `scn:` QCodes normalize to the
  canonical code. Unknown incoming values remain lossless and visible; they are not silently
  replaced or removed during unrelated edits.
- The default validation profile checks every repeated value against the frozen vocabulary and
  emits one stable blocking issue when any values are unknown or retired.
- XMP sidecars and embedded raster writes use the unordered `Iptc4xmpCore:Scene` bag. An
  authoritative clear removes that property.
- JSON sidecars, metadata history, batch edits, imports, templates, field variables, browser
  search, copy/paste, rendered exports, and FTP/SFTP preparation use the same canonical values.

## Automated evidence

Focused tests cover:

- URI and QCode alias normalization, duplicate removal, editor-label conversion, and preservation
  of unknown plain values.
- All current values through the default allowed-values rule and per-item rejection of an unknown
  repeated value.
- XMP-sidecar and embedded-JPEG bag writes, readback, unrelated metadata preservation, and
  authoritative clear behavior.
- Template persistence, `{field:scene}` and `{field:Scene Code}` interpolation, browser/export
  propagation, and real-file delivery sidecar overlay.

Verification commands:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataValidationTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests' \
  -only-testing:'Aagedal Photo Agent Tests/PresetVariableInterpolatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/EditExportPipelineTests'

xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests'
```

The first command passes 52 tests and the interoperability suite passes 17 tests. A complete
`build-for-testing` of the app scheme also succeeds.

External Bridge, Photo Mechanic, IPTC reference-tool, and non-JPEG container verification remain
part of the Phase 0 and Phase 1 interoperability gates.
