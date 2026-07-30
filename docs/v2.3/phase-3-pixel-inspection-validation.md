# Phase 3 pixel-inspection slice — validation

## Implemented

- Extracted fit-to-view hover mapping and true-pixel crop placement into
  `ImageInspectionGeometry`.
- Refactored Advanced Export hover and loupe crop placement to use the shared geometry.
- Added a workspace-owned linked hover sample to Image Analysis.
- Added a visible crosshair and zero-based source-pixel readout.
- Mapped developed representation hover positions through crop and straighten to the original
  source pixel frame.
- Kept letterbox areas outside the sampling surface and added an accessible center-pixel action.

This slice does not claim that the Analysis thumbnail is a true-pixel rendering. The reusable
true-pixel crop utility currently continues to back Advanced Export; the full Analysis loupe and
derived-view rendering arrive with the remaining Phase 3 views and cache work.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/ViewportStateTests" \
  -only-testing:"Aagedal Photo Agent Tests/ImageInspectionGeometryTests" \
  -only-testing:"Aagedal Photo Agent Tests/DisplayImageTransformTests"
```

Result: 25 tests passed in 3 suites.

Coverage includes:

- inset fit geometry and letterbox rejection;
- normalized hover mapping;
- source-pixel sampling through all eight EXIF orientations;
- developed crop and straighten mapping;
- top-left hover to bottom-left Core Image crop conversion;
- true-pixel crop clamping at image edges;
- existing fit, actual-pixel, custom zoom, pan, and round-trip viewport behavior.

## Manual validation remaining for the Phase 3 gate

- Inspect hover alignment on the redistributable orientation/crop fixture corpus.
- Compare HDR and SDR display behavior.
- Verify alignment once normal and derived views are shown side by side.
- Validate the larger scope layouts and selected-region scopes.
