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
- Added Normal, Red, Green, Blue, and Luminance view modes above the analysis image.
- Evaluated the channel matrices in extended-linear sRGB, preserved alpha and image geometry,
  and labeled the active method in the UI.
- Fed the selected channel/luminance visualization to the existing scope and selected-region
  paths while keeping findings and source facts bound to the selected original/developed
  representation.
- Added a bounded compression-residual view from an ImageIO JPEG quality-0.90 re-encode,
  amplified as a 12× absolute linear-sRGB difference after compositing alpha over 50% gray.
- Displayed the normal reference and compression residual side by side from the same
  orientation-aware, at-most-2,048-pixel Analysis preview.
- Linked hover crosshairs and retained scope-selection overlays across both panes, and continued
  to feed the derived pixels to the existing full-image/selected-region scope path.
- Published the exact method beside the view and kept a visible warning that ordinary detail,
  gradients, resaving, and prior processing can produce bright residuals and that the view does
  not establish manipulation.

This slice does not claim that the Analysis thumbnail is a true-pixel rendering. The reusable
true-pixel crop utility currently continues to back Advanced Export; the full Analysis loupe,
and bounded derived-view cache arrive with the remaining Phase 3 work. The compression residual
is explicitly a bounded preview; a future report figure must persist its actual pixel dimensions
alongside the fixed method parameters.

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

Channel/luminance command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisPixelViewRendererTests"
```

Result: 6 tests passed in 1 suite.

Coverage includes identity-preserving normal output, grayscale channel isolation, alpha
preservation, Rec. 709 relative-luminance primary ordering, output geometry, and explicit method
labels. Compression-residual coverage additionally fixes the 0.90 quality, 12× difference gain,
and 50% gray alpha matte; verifies opaque, geometry-preserving output; and confirms that a
high-frequency color fixture exposes more reconstruction residual than a uniform field.

The full `Aagedal Photo Agent Tests` target passed 709 tests in 99 suites after the final
integration.

## Manual validation remaining for the Phase 3 gate

- Inspect hover alignment on the redistributable orientation/crop fixture corpus.
- Compare HDR and SDR display behavior.
- Confirm reference/residual alignment in the new side-by-side view at every supported workspace
  size.
- Switch among Normal, R, G, B, Luma, and Residual and confirm every derived view remains aligned
  with the crosshair, selected region, and scopes.
- Resize the source/scope divider and every divider in the one/two/four-up layouts.
- Switch each card among Waveform, RGBY Parade, Vectorscope, and Chromaticity and confirm the
  existing sidebar remains unchanged.
- Confirm Original Source / Developed Preview changes refresh every visible scope.
- Drag regions in every direction, including near each image edge, and confirm every visible
  scope switches between the retained selection and full image without extra renders during drag.
