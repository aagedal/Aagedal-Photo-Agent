# Headline and localized Title validation

**Date:** 2026-08-24  
**Scope:** Phase 1 metadata-model and I/O exit item for independent Headline and Dublin Core Title

## Implemented boundary

- `IPTCMetadata.title` remains the shipped JSON/API compatibility key for IPTC Headline and maps
  only to IIM 2:105 plus `photoshop:Headline`.
- Ordered `LocalizedMetadataText` values independently represent every `dc:title/rdf:Alt` item and
  its exact `xml:lang` tag. A nil collection means a legacy/unmodeled caller must leave the carrier
  untouched; an empty collection is an explicit modeled clear.
- The app no longer reads `dc:title` or IIM Object Name as a fallback Headline.
- Legacy JSON and sidecar records without `localizedTitles` decode as nil and preserve embedded
  Title alternatives during merge and authoritative descriptive replacement.
- Reconciliation treats that legacy sidecar nil as “no opinion,” so embedded Title alternatives
  alone cannot make a newer image timestamp invalidate otherwise matching sidecar edits. Modeled
  alternatives and explicit empty clears still participate in conflict detection.
- Embedded, export, delivery-staging, and descriptive-write-boundary writes carry localized Titles
  through `EditorialStructuredWriteData`; they do not leave an older target `dc:title` behind.
- XMP sidecars persist an explicit empty clear with the app-private
  `aaphoto:LocalizedTitleCleared` marker. The marker is not a synthetic Title value: it restores
  empty-as-clear intent on reload, is removed when a modeled Title is written, and legacy nil still
  leaves both the carrier and any pending clear untouched.
- Read-back verification compares the exact ordered language tags and values when the field is
  modeled. Legacy nil omits localized Title from each item's checked fields, and delivery receipts
  record that applicable per-item field set instead of claiming the carrier was checked.
- The Xcode project uses the checked-in `Vendor/SwiftExif` fork, based on upstream 1.9.10 revision
  `47249c72b613ebab8e4514f4adf05bb8000a1908`. Its new ordered language-alternative carrier is used
  whenever an `rdf:Alt` is genuinely multilingual; the legacy scalar case remains for one
  `x-default` item to avoid changing unrelated structured-XMP shapes.

## Automated evidence

The local fork compiled independently:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/aagedal-headline-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/aagedal-headline-swiftpm-cache \
swift build --disable-sandbox --scratch-path /tmp/aagedal-headline-swiftexif-build
```

Result: `Build complete!` after compiling all 173 SwiftExif source jobs.

The focused app and interoperability run used isolated DerivedData:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/aagedal-headline-title-derived \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/IPTCMetadataCodableTests' \
  -only-testing:'Aagedal Photo Agent Tests/MergedTests' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveRecordTests' \
  -only-testing:'Aagedal Photo Agent Tests/SidecarReconciliationTests'
```

Result: `** TEST SUCCEEDED **`; 69 tests in five suites passed. The coverage includes:

- a three-language packet (`x-default`, `nb-NO`, `nn`) through reader/writer regeneration;
- Headline-only sidecar and embedded-JPEG edits preserving every Title alternative;
- no Headline fallback from a localized Title;
- JSON round trip and legacy JSON defaulting to the unmodeled nil state;
- merge, authoritative replacement, explicit clear, modeled descriptive-conflict semantics, and a
  newer-image verdict proving legacy sidecar nil is a reconciliation wildcard; and
- the existing structured editorial XMP suite, including single-`x-default` compatibility.

An earlier focused run exposed the single-`x-default` carrier-shape regression in structured
locations. The parser compatibility rule above fixed it, and the complete 69-test set passed on the
subsequent run.

The production-path closure run also used isolated DerivedData:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/aagedal-title-production-derived \
  -only-testing:'Aagedal Photo Agent Tests/EditorialMetadataInteroperabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/IPTCMetadataVerificationTests' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveMetadataWriteBoundaryTests' \
  -only-testing:'Aagedal Photo Agent Tests/EditExportPipelineTests' \
  -only-testing:'Aagedal Photo Agent Tests/DeliveryStagingProductionFactoryTests' \
  -only-testing:'Aagedal Photo Agent Tests/StagedDeliveryCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/VerifiedDeliveryUploadCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/DeliveryReceiptAssemblerTests'
```

Result: `** TEST SUCCEEDED **`; 104 tests in eight suites passed. This adds production overlay,
export set/clear, delivery staging and read-back, localized-only merge and authoritative clear,
sidecar clear-tombstone reload, honest per-item verification fields, and receipt evidence.

After extending the packet fixture with ordered duplicate `nb-NO` tags and an empty `nn` value, the
32-test interoperability suite was rerun separately and passed. The regenerated packet preserved
every item, tag, value, duplicate, and position exactly.

## Remaining release evidence

This closes the app's model/I/O implementation item. External Bridge, Photo Mechanic, and official
IPTC fixture round trips remain part of the broader Phase 0/release interoperability gates.
