# Analysis fixture corpus validation — 2026-08-25

## Scope and result

The Phase 0 redistributable-fixture gate now has a repository-owned CC0-1.0 baseline corpus at
`Aagedal Photo Agent Tests/Fixtures/AnalysisCorpus`. Its provenance README and machine-readable
manifest identify every artifact's origin, reviewed SHA-256, expected properties, redistribution
terms, personal-data status, generation recipe, related editorial fixtures, and explicit non-claims.

The corpus adds 17 generated raster/container assets and two synthetic semantic-state JSON files:

- a known 16 × 12 RGBA pixel/alpha grid, SDR photographic gradient, simulated scan/halftone, and
  benign feathered composite;
- known one-pass and two-pass JPEG recipes;
- one asymmetric source encoded with each of the eight EXIF orientations;
- two-frame GIF and TIFF sources plus a seven-byte malformed JPEG;
- raw metadata contracts for stripped, conflicting, non-ASCII/multiline, and malformed values;
- absent, valid/untrusted, valid/trusted, and invalid C2PA presentation-state contracts that state
  plainly that they are not signed media.

The sibling generated editorial corpus remains the source for RAW+XMP sidecar routing,
namespace-preserving metadata, and source-write-refusal fixtures. The analysis corpus references
those files instead of duplicating them.

## Automated validation

`AnalysisFixtureCorpusTests`, added to the already registered
`EditorialContainerFixtureTests.swift` test source, provides four focused tests. It requires exact
manifest/directory agreement, verifies every SHA-256 and provenance/expectation entry, decodes and
checks dimensions/frame counts/alpha/orientation, confirms the JPEG recipes differ, requires the
malformed source to fail decode, and checks the metadata/C2PA case sets.

The focused macOS run passed:

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/aagedal-analysis-corpus-derived \
  -only-testing:'Aagedal Photo Agent Tests/AnalysisFixtureCorpusTests'
```

Result: **4 tests in 1 Swift Testing suite passed with no failures**.

A follow-up run selected both `AnalysisFixtureCorpusTests` and the sibling
`EditorialContainerFixtureTests`: **8 tests in 2 suites passed with no failures**. This covers the
reused RAW-sidecar and complex-container boundary alongside the new analysis inventory.

The generator was then run a second time. A manifest-driven SHA-256 comparison still passed for
all 19 declared artifacts. `jq` validation of all three JSON files, standalone generator
type-checking, and `git diff --check` also passed.

## Honest coverage boundary

The corpus closes the repository-owned redistributable baseline gate; it does not claim vendor or
device representativeness. The generated JPEG pair is not camera-created, the scan is a synthetic
surrogate, and the C2PA JSON cases exercise typed app states rather than signature parsing.

The manifest therefore records these unavailable authentic additions instead of fabricating them:
camera JPEG and RAW originals, decodable HEIC/HEIF, HDR gain-map media, and signed C2PA trust-state
media. AI-generated examples are not included because the separate on-device AI-origin model and
license gate has not passed. These are interoperability/calibration additions if confirmed
redistribution rights and reproducible provenance become available; they remain limitations for
manual/device claims.

The separate Phase 3 checklist item for manual alignment and color behavior remains open. This
validation establishes legal/reproducible inputs and automated properties, not a human display,
HDR, or vendor-tool validation result.
