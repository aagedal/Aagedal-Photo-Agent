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
- Connected pane resize, pan, and magnification events to the atomic `ComparisonCoordinator`.
  Fit, decoded-pixel 100%, custom zoom, linear/nearest interpolation, temporary unlock/relock,
  alignment reset, and edge-clamping feedback are now visible in the comparison header.

## Automated validation

The existing `ComparisonSessionTests` selection test covers the exactly-two requirement, supported
format filtering, and Browser-visible ordering. The comparison-session suite is run with:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/ComparisonSessionTests"
```

Result: 7 tests passed in 1 suite. A full `build-for-testing` of the app and test targets also
completed successfully under Swift 6.

## Remaining true-pixel gate

Comparison remains intentionally bounded to 4096-pixel decoded previews. The controls exercise the
shared viewport and synchronization semantics, but 100% cannot yet promise one source pixel per
display pixel for a larger source. The next slice must add a cancellable, memory-bounded detail
upgrade and visually validate fit, true source pixels, custom zoom, locked pan/zoom, temporary
unlock, saved offset, clamping feedback, and interpolation on mismatched fixtures. The combined
delivery-plan control/zoom item remains unchecked until that gate passes.
