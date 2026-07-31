# Phase 4 photo-markup slice — validation

## Implemented

- Added normalized, top-left-origin photo geometry that remains independent of preview size and
  zoom.
- Added persisted line, arrow, distance, rectangle, ellipse, and label annotation kinds.
- Added stable palette identifiers and validated custom RGBA values without persisting
  display-profile conversions.
- Added validated stroke/fill style, visibility, timestamps, stable IDs, and finding references.
- Added case-owned insert, replacement, and removal operations.
- Bumped `AnalysisCase` to schema version 3 and migrate version 1 and version 2 cases with an empty
  annotation collection while preserving the version 2 analyzer cache.
- Reject duplicate annotation IDs, invalid kind/geometry combinations, non-finite or out-of-range
  coordinates and colors, collapsed geometry, invalid styles, empty labels, invalid timestamps,
  and duplicate or empty finding references before persistence.
- Exposed case annotations and guarded mutations through `AnalysisWorkspaceModel`; stale
  source-changed cases remain read-only.
- Added a segmented select/line/arrow/distance/rectangle/ellipse/label toolbar over the Analysis
  image, with live creation previews and a text prompt for labels.
- Rendered persistent annotations over normal and derived image panes, including linked duplicate
  overlays in the compression-residual comparison.
- Added selection hit-testing, visible selection handles, toolbar and Delete-key removal, and
  color editing for the selected annotation.
- Added a fixed high-contrast yellow/blue/orange/purple/white/black palette plus an RGBA custom
  color picker. Every stroke receives an adaptive contrast outline so black and light colors stay
  visible over varied image content.
- Routed creation, rendering, and hit-testing through the original/source/current transform chain,
  preserving source attachment across EXIF orientations and Developed crop/straighten changes.

The annotation coordinates describe the original image's display-oriented frame. Rendering,
hit-testing, developed-preview placement, source-pixel measurement, and report export must all use
the shared `DisplayImageTransform` rather than introducing surface-specific coordinate math.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisCaseTests"
```

Result: 18 tests passed in 1 suite.

Coverage includes:

- version 1 to version 3 migration;
- version 2 to version 3 migration with analyzer-run preservation;
- atomic annotation persistence and reopening without source or XMP writes;
- every planned photo-markup kind and its required normalized geometry;
- custom color and linked-finding round-trip;
- rejection of mismatched, out-of-range, and duplicate annotations;
- reverse-drag geometry standardization and collapsed-gesture rejection;
- persistent-to-developed coordinate round-trips with EXIF orientation, crop, and straighten.

## Remaining Phase 4 work

- Add per-surface undo/redo transactions.
- Add annotation list, layer visibility, and keyboard operations.
- Add source-pixel measurement and user calibration.
- Add finding-link workflow in the UI.
- Validate all orientations, representation changes, view sizes, reports, keyboard-only use, and
  VoiceOver.
