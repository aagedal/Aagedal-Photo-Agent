# Phase 6 report snapshot foundation — validation

## Implemented

- Added `AnalysisReportSnapshot`, a deep value snapshot that is the only supported starting point
  for report rendering.
- Re-hash the current source URL immediately before snapshot creation and require an exact SHA-256
  revision match. A changed source fails before any report inputs are frozen.
- Freeze case identity, app/build identity, source revision, selected representation, analyzer run
  methodology, source facts, raw metadata, included findings, photo markup, timestamp evidence, and
  map evidence.
- Remove analyzer output from the frozen run records so an excluded finding is not retained in a
  second collection that a renderer could accidentally use.
- Sort analyzers, findings, raw metadata, and timestamp evidence deterministically while preserving
  user-authored photo/map layer order.
- Capture the exact map viewport, live style, investigator location, and visible case annotations
  as WGS-84 schematic input. Hidden map annotations remain excluded.
- Include a coordinate/span/style Apple Maps URL for live reference plus an explicit statement that
  no Apple tiles or imagery are embedded.
- Record the map imagery decision in `adr-004-map-report-evidence.md`.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisReportSnapshotTests"
```

Result: 4 tests passed in 1 suite.

Coverage includes:

- exact viewport, WGS-84 disclosure, hidden-layer filtering, and live reference parameters;
- snapshot JSON round-trip;
- rejection after source bytes change;
- report-inclusion filtering and immutability across later case edits; and
- omission of a map figure when no exact viewport was captured.

## Remaining Phase 6 work

- Report field selections and sensitive-data warning.
- PDF page composition, schematic rendering, figures, legends, methodology, and appendix.
- Progress/cancellation, atomic output, cleanup, semantic tests, and rendered A4/US Letter QA.
