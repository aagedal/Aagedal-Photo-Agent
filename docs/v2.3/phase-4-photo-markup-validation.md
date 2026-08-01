# Phase 4 photo-markup slice — validation

## Implemented

- Added normalized, top-left-origin photo geometry that remains independent of preview size and
  zoom.
- Added persisted line, arrow, distance, rectangle, ellipse, and label annotation kinds.
- Added stable palette identifiers and validated custom RGBA values without persisting
  display-profile conversions.
- Added validated stroke/fill style, visibility, timestamps, stable IDs, and finding references.
- Added case-owned insert, replacement, and removal operations.
- Bumped `AnalysisCase` to schema version 4. Versions 1 and 2 migrate with an empty annotation
  collection, version 2 preserves its analyzer cache, and version 3 preserves annotations without
  inventing calibration state.
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
- Added a bounded, photo-surface-owned transaction history for annotation additions, edits, and
  removals, with persistent undo/redo, redo-branch invalidation, toolbar controls, and standard
  Command-Z / Shift-Command-Z shortcuts. Opening or rebinding a case clears the surface history.
- Added an ordered, keyboard-selectable case-sidebar layer list with per-annotation visibility,
  grouped Show All / Hide All transactions, Delete-key removal, and accessible state labels.
- Added source-pixel distance calculation through the shared original-image transform, visible
  measurement labels on normal and derived panes, and an accessible measurement summary. Values
  remain independent of preview size, EXIF orientation, Developed crop, straighten, and zoom.
- Added one user-defined real-world calibration per case, attached to a selected distance segment.
  The editor accepts millimeters, centimeters, meters, inches, or feet; every distance label shows
  the converted length alongside the underlying source-pixel length. Calibration replacement and
  removal use the photo annotation transaction history, so delete and undo restore the scale.
- Added a calibration badge to the annotation layer list and accessible labels for the calibration
  editor, known segment length, and converted overlay summaries.

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

Result: 27 tests passed in 1 suite.

Coverage includes:

- version 1 and version 2 migration to version 4, including analyzer-run preservation;
- version 3 annotation migration without fabricated calibration;
- atomic annotation persistence and reopening without source or XMP writes;
- every planned photo-markup kind and its required normalized geometry;
- custom color, visibility state, and linked-finding round-trip;
- rejection of mismatched, out-of-range, and duplicate annotations;
- reverse-drag geometry standardization and collapsed-gesture rejection;
- persistent-to-developed coordinate round-trips with EXIF orientation, crop, and straighten.
- bounded undo/redo, redo-branch invalidation, and persistently valid snapshot restoration.
- source-pixel distance through all eight EXIF orientations and Developed representation changes.
- positive finite calibration validation and rejection of multiple case calibrations;
- calibrated scale math, preferred-unit formatting, and cross-unit conversion.
- calibration replacement through photo-surface undo and redo transactions.

## Remaining Phase 4 work

- Add finding-link workflow in the UI.
- Validate all orientations, representation changes, view sizes, reports, keyboard-only use, and
  VoiceOver.
