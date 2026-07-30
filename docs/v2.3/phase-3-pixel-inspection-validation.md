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
- Added immutable scope render requests containing mode, display options, and bounded output
  pixel size.
- Kept the existing sidebar on its established 720-pixel render path while sharing its
  presentation sizing rules.
- Added a vertically resizable scope area to Pixel Analysis with one, two, and four-up layouts.
- Made each scope card independently selectable and backing-scale aware.
- Limited render work to visible scope cards and cancel/clear hidden cards when the layout
  changes.
- Fed scopes from the representation currently displayed in Image Analysis, including the
  developed preview when selected.
- Added a Full Image / Selection source control shared by every visible Analysis scope.
- Added normalized drag selection on the displayed representation with a visible retained
  overlay, clear action, and accessible center-region action.
- Committed scope selection only when the drag ends so superseded CPU renders do not accumulate.
- Converted normalized selection bounds outward to stable integer pixel edges and cropped one
  shared `CGImage` input for all visible scope cards.

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

Scope request command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/ScopeRenderRequestTests"
```

Result: 4 tests passed in 1 suite.

Coverage includes:

- point-to-backing-pixel conversion and the 64–2,048 pixel dimension bounds;
- rejection of collapsed, infinite, and invalid presentation geometry;
- established waveform, vectorscope, and chromaticity presentation shapes;
- exact non-square output dimensions through the unified renderer.

The full test target also completed a successful build-for-testing after the Image Analysis
integration.

A combined regression run of `ScopeRenderRequestTests`, `ChromaticityScopeTests`,
`ViewportStateTests`, and `DisplayImageTransformTests` passed 28 tests in 4 suites.

Selected-region command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisScopeSelectionTests" \
  -only-testing:"Aagedal Photo Agent Tests/ScopeRenderRequestTests"
```

Result: 8 tests passed in 2 suites.

Coverage includes direction-independent and clamped drag geometry, collapsed/invalid selection
rejection, stable normalized-to-pixel boundary conversion, cropped input dimensions, and the
existing scope request/rendering contract.

The final combined run added `ImageInspectionGeometryTests` and passed 12 tests in 3 suites,
including edge-clamped selection drags that begin over displayed pixels.

## Manual validation remaining for the Phase 3 gate

- Inspect hover alignment on the redistributable orientation/crop fixture corpus.
- Compare HDR and SDR display behavior.
- Verify alignment once normal and derived views are shown side by side.
- Resize the source/scope divider and every divider in the one/two/four-up layouts.
- Switch each card among Waveform, RGBY Parade, Vectorscope, and Chromaticity and confirm the
  existing sidebar remains unchanged.
- Confirm Original Source / Developed Preview changes refresh every visible scope.
- Drag regions in every direction, including near each image edge, and confirm every visible
  scope switches between the retained selection and full image without extra renders during drag.
