# Phase 6 PDF report foundation - validation

## Implemented

- Added an **Export PDF** action to Image Analysis. The action is unavailable when the current source
  no longer matches the case revision.
- Re-hash the source before freezing report inputs and render solely from `AnalysisReportSnapshot`.
- Added A4 and US Letter output with a fixed paper palette, running case header, page footer, page
  number, snapshot identifier, and PDF title/author/creator metadata.
- Added cover, source revision and provenance, included findings, photo-annotation legend, calibrated
  measurement disclosure, timestamp evidence, untimed observations, location evidence, methodology,
  limitations, analyzer runs, and raw metadata sections.
- Render map evidence as an app-generated WGS-84 schematic. Apple map tiles and imagery are never
  read from the case or embedded in the report.
- Added a Pixel evidence chapter with an aspect-preserving annotated source overview and, when an
  Original-view scope region is selected, a true-pixel evidence crop. The immutable snapshot records
  exact display-oriented and source-storage pixel bounds. The report identifies 1:1 source-pixel
  extraction and no interpolation, and overlays only annotations that intersect the selected crop.
- Added export controls for canonical paths, camera serial numbers, exact coordinates/live map links,
  and the raw metadata appendix. The export sheet warns that these fields can identify a person,
  device, or location. Sensitive raw metadata keys are filtered when their corresponding field is
  disabled.
- Added progress updates at closed-page boundaries so the UI can repaint and cancellation can be
  observed safely between sections. Destination writes use Foundation's atomic replacement option;
  rendering creates no persistent intermediate map imagery or report file to clean up.
- Long text uses TextKit-measured word-wrapped pagination instead of fixed-height clipping, with a
  physical-line safety reserve at page boundaries.

## Automated validation

Command:

```sh
xcodebuild test \
  -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/aagedal-photo-agent-v23-verify \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisReportSnapshotTests" \
  CODE_SIGNING_ALLOWED=NO
```

Result: 9 tests passed in 1 suite.

The report-specific assertions cover:

- A4 and US Letter media-box dimensions;
- deterministic section text and a multi-page document structure;
- source SHA-256, finding, annotation, calibration, timeline, observation, map disclosure, methodology,
  limitations, analyzer version, and cache-key presence;
- monotonic progress completion;
- sensitive-path omission and raw-metadata exclusion;
- exact-revision rejection and immutable snapshot behavior;
- orientation-aware frozen crop bounds and snapshot round-tripping;
- embedded true-pixel crop captions and explicit missing-image states; and
- long Unicode findings, 70 annotations, and organically flowing multi-page content.

## Visual validation

The A4 evidence-rich fixture, US Letter privacy/minimal fixture, A4 true-pixel crop fixture, and A4
long-Unicode/70-annotation fixture were rendered to PNG at 110 dpi with Poppler. All 48 pages were
inspected. Page bounds, margins, headings, long-text continuations, source/crop aspect ratios, crop
captions, annotation flow, rules, map schematic, callouts, headers, footers, and page numbering render
without clipping, overlap, orphaned figure headings, broken glyphs, or theme-dependent colors.

## Remaining enhancement

Selected derived-view report figures remain a follow-up enhancement. The 2.3 Phase 6 exit gate is
met by the frozen source overview and selected true-pixel evidence crop, together with the existing
methodology and limitation disclosures for derived analysis views.
