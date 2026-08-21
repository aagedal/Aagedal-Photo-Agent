# Digital Image GUID validation

**Validated:** 2026-08-21  
**Standard baseline:** IPTC Photo Metadata Standard 2025.1  
**Property:** `Iptc4xmpExt:DigImageGUID`

## Implemented contract

- `IPTCMetadata.digitalImageGUID` is a distinct optional scalar; it is not derived from the
  filename, Job ID, Image Supplier Image ID, or any application-side record identifier.
- Existing XMP values are read verbatim and survive JSON sidecars, history, copy/reconciliation,
  batch editing, rendering, and delivery preparation.
- New values may be assigned only through an explicit metadata edit, import configuration,
  template, batch action, or history restoration. A normal edit never generates or rotates a GUID.
- Template append mode treats the identifier as atomic and replaces it instead of concatenating
  two identifiers.
- The field intentionally accepts agency-specific identifier forms. IPTC defines the property as
  text, so Photo Agent does not rewrite incoming identifiers into UUID syntax.
- An explicit empty write removes `Iptc4xmpExt:DigImageGUID`; an unrelated write leaves it intact.

## Interoperability evidence

The focused tests cover:

- Omission from sparse write dictionaries when no identifier was assigned.
- Codable and template persistence, field-label aliases, and variable interpolation.
- XMP sidecar write/read using the IPTC Extension namespace.
- Embedded JPEG write/read through SwiftExif.
- Preservation of an existing identifier during an unrelated caption edit.
- Authoritative clear behavior.
- Rendered-export propagation from a pending XMP sidecar.

Command:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests' \
  -only-testing:'Aagedal Photo Agent Tests/PresetVariableInterpolatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/EditExportPipelineTests'

xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/ToWriteFieldsTests' \
  -only-testing:'Aagedal Photo Agent Tests/HasIPTCDifferencesTests' \
  -only-testing:'Aagedal Photo Agent Tests/MergedTests' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveRecordTests' \
  -only-testing:'Aagedal Photo Agent Tests/IPTCMetadataCodableTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataSidecarServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataValidationTests'
```

Result: **160 tests passed** across the two focused runs (53 + 107).

## Remaining evidence

- Confirm current Adobe Bridge and Photo Mechanic display/write behavior.
- Add the field to TIFF, PNG, HEIC/HEIF, JPEG XL, and representative RAW+XMP fixtures.
- Include it in the generated support report once that Phase 1 deliverable exists.
