# Editorial rights XMP validation

**Date:** 2026-08-21  
**Scope:** journalistic metadata workflow, Phase 1 read/write boundary

## Implemented behavior

- Rights Usage Terms maps to the localized `xmpRights:UsageTerms` property and Web Statement of
  Rights maps to the scalar `xmpRights:WebStatement` property.
- Both values survive versioned JSON sidecars, metadata templates and variables, import presets,
  single and batch editing, metadata history, rendered export, and FTP/SFTP preparation.
- Standalone XMP sidecars and embedded JPEG metadata use the same read/write mapping. Authoritative
  empty values remove each property, while unrelated XMP properties remain preserved.
- The shared default validation profile accepts empty web statements, accepts non-empty HTTP and
  HTTPS URLs, and emits a blocker for malformed non-empty values.
- The CC0 preservation fixture contains both rights properties so no-op and unrelated-caption
  preservation tests cover them.

## Automated validation

The following focused macOS suites passed:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/IPTCMetadataCodableTests' \
  -only-testing:'Aagedal Photo Agent Tests/ToWriteFieldsTests'
```

Result: 46 tests in three suites passed. Coverage includes XMP sidecar and embedded-JPEG
round trips, authoritative clears, JSON persistence, write-field mapping, semantic no-op, and
unrelated-property preservation.

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataValidationTests' \
  -only-testing:'Aagedal Photo Agent Tests/PresetVariableInterpolatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/EditExportPipelineTests'
```

Result: 43 tests in three suites passed. Coverage includes HTTP(S) validation, field-reference
variables, and sidecar-to-rendered-JPEG delivery propagation.

The app and complete test targets also passed `xcodebuild build-for-testing`.
A final combined run passed all 94 tests across the seven focused suites.

## Remaining boundary work

The current model exposes one usage-terms string and writes it as the XMP `x-default` language
alternative. Reading, preserving, and editing additional language alternatives remains open.
External Bridge, Photo Mechanic, and IPTC reference-tool checks plus TIFF, PNG, HEIC/HEIF, JPEG XL,
and representative RAW+XMP fixtures also remain part of the Phase 0/1 exit gates.
