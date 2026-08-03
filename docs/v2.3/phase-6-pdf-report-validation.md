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
- Added export controls for canonical paths, camera serial numbers, exact coordinates/live map links,
  and the raw metadata appendix. The export sheet warns that these fields can identify a person,
  device, or location. Sensitive raw metadata keys are filtered when their corresponding field is
  disabled.
- Added progress updates at closed-page boundaries so the UI can repaint and cancellation can be
  observed safely between sections. Destination writes use Foundation's atomic replacement option;
  rendering creates no persistent intermediate map imagery or report file to clean up.
- Long text uses measured word-wrapped pagination instead of fixed-height clipping.

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

Result: 6 tests passed in 1 suite.

The report-specific assertions cover:

- A4 and US Letter media-box dimensions;
- deterministic section text and a multi-page document structure;
- source SHA-256, finding, annotation, calibration, timeline, observation, map disclosure, methodology,
  limitations, analyzer version, and cache-key presence;
- monotonic progress completion;
- sensitive-path omission and raw-metadata exclusion; and
- the existing exact-revision rejection and immutable snapshot behavior.

## Visual validation

The A4 evidence-rich fixture and US Letter privacy/minimal fixture were each rendered to nine PNG
pages with Ghostscript at 110 dpi. All 18 pages were inspected. Page bounds, margins, headings,
wrapping, rules, map schematic, callouts, headers, footers, and page numbering rendered without
clipping, overlap, broken glyphs, or theme-dependent colors.

## Remaining Phase 6 work

- Add source and derived evidence-image figures.
- Add source-pixel evidence crop export with an explicit interpolation/scale label.
- Exercise long findings, Unicode, missing figures, many annotations, and organically flowing
  multi-page sections rather than only one section per report chapter.
