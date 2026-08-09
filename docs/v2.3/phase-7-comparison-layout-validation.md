# Phase 7 comparison layouts - validation

## Implemented

- Added a Browser layout-menu entry that is enabled only when exactly two supported visible images
  are selected. Selection order follows the visible Browser order, not the unordered selection set.
- Added source identification before presentation. Each pane is bound to an exact streaming SHA-256
  `SourceImageRevision`; failures surface a retry state instead of silently comparing a stale path.
- Added side-by-side and stacked comparison surfaces using native adjustable macOS split dividers.
- Added a single-pane A/B presentation with an explicit A/B switch.
- Added filename and Original/Committed Edit badges, visible pane focus, partial-decode handling,
  bounded 4096-pixel previews, HDR presentation, close/cancel behavior, and accessibility labels.

## Automated validation

The existing `ComparisonSessionTests` selection test covers the exactly-two requirement, supported
format filtering, and Browser-visible ordering. The comparison-session suite is run with:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/ComparisonSessionTests"
```

Result: 6 tests passed in 1 suite. A full `build-for-testing` of the app and test targets also
completed successfully under Swift 6.

## Remaining interaction gate

The layout slice intentionally stays fit-only. The next Phase 7 slice must connect the existing
`ComparisonCoordinator` transactions to both panes and visually validate fit, true pixels, custom
zoom, locked pan/zoom, temporary unlock, saved offset, clamping feedback, and interpolation. The
delivery-plan control/zoom item remains unchecked until that gate passes.
