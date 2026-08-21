# Image Supplier Image ID validation

**Validated:** 2026-08-21  
**Standard baseline:** IPTC Photo Metadata Standard 2025.1  
**Property:** `Iptc4xmpExt:ImageSupplierImageID`

## Implemented contract

- `IPTCMetadata.imageSupplierImageID` is a distinct optional scalar. It is not derived from the
  Digital Image GUID, Job ID, filename, application-side record identity, or the planned structured
  Image Supplier value.
- Existing values survive JSON sidecars, history, copy/reconciliation, batch editing, rendering,
  and delivery preparation.
- The field accepts agency-specific text values without rewriting them into UUID or URI syntax.
- Template append mode treats the identifier as atomic and replaces it instead of concatenating
  identifiers.
- An explicit empty write removes `Iptc4xmpExt:ImageSupplierImageID`; an unrelated write leaves it
  intact and does not alter the Digital Image GUID.

## Interoperability evidence

Focused tests cover:

- Sparse write dictionaries and independence from Digital Image GUID.
- Codable and metadata-sidecar persistence, field labels, and variable interpolation.
- XMP sidecar and embedded JPEG read/write using the IPTC Extension namespace.
- Preservation during an unrelated caption edit.
- Authoritative clear behavior without clearing Digital Image GUID.
- Metadata difference, additive merge, and descriptive replacement semantics.
- Rendered-export propagation from a pending XMP sidecar.

Command:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests' \
  -only-testing:'Aagedal Photo Agent Tests/PresetVariableInterpolatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/EditExportPipelineTests' \
  -only-testing:'Aagedal Photo Agent Tests/ToWriteFieldsTests' \
  -only-testing:'Aagedal Photo Agent Tests/IPTCMetadataCodableTests'

xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/HasIPTCDifferencesTests' \
  -only-testing:'Aagedal Photo Agent Tests/MergedTests' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveRecordTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataSidecarServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataValidationTests'
```

Result: **166 tests passed** across the two focused runs (89 + 77).

## Remaining evidence

- Confirm current Adobe Bridge and Photo Mechanic display/write behavior.
- Add the field to TIFF, PNG, HEIC/HEIF, JPEG XL, and representative RAW+XMP fixtures.
- Include it in the generated support report once that Phase 1 deliverable exists.
