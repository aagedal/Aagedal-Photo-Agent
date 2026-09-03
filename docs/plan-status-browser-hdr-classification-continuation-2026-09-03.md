# Plan-status Browser HDR-classification continuation — 2026-09-03

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Browser metadata batches no longer perform native-HDR
ImageIO and mapped JPEG/HEIF gain-map inspection while merging metadata on MainActor. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Serialized classification boundary

`BrowserHDRClassificationService` receives one ordered URL batch and request identity. Its actor serializes the
existing native-HDR detector, including container-header and gain-map signature inspection, and returns immutable
Boolean evidence for every inspected URL. Cancellation is sampled before the batch and before and after each
synchronous, non-preemptible classification. Results distinguish cancellation before any read, after an exact
partial prefix, and after the final classification.

A privacy-safe `OSSignposter` interval records only completion state and aggregate inspected counts. It never
records a path or filename.

## Browser publication lifetime

Browser metadata loading starts HDR classification alongside its existing serialized XMP load and asynchronous
metadata read. Before applying a batch, it validates the current folder, metadata request identity, classification
request identity, exact ordered URL batch, and complete evidence. Partial, cancelled, or superseded snapshots are
never merged into `ImageFile.isNativeHDR`.

The MainActor merge now performs only an in-memory lookup plus the existing pure RAW-preference projection; it no
longer calls `SupportedImageFormats.isHDR`.

## Characterization and validation

Four new characterizations prove complete classification runs serially away from MainActor, pre-cancellation
performs no inspection, cancellation after a non-preemptible read reports the exact committed prefix, and Browser
awaits complete request-matched evidence without calling the native-HDR detector during its MainActor merge.

The focused Browser filesystem-boundary selection passed all 9 tests in two suites:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/BrowserXMPSidecarLoadServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/BrowserHDRClassificationServiceTests'
```

The adjacent Browser XMP/HDR, source-revision, technical-metadata, full-screen presentation, and metadata-batch
selection passed all 71 tests in six suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,947 logical tests in 227 suites with zero failures or skips in
61.998 seconds. Result bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.03_23-20-57-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
