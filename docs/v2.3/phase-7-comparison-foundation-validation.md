# Phase 7 comparison foundation - validation

## Implemented

- Added source-bound `ComparisonSource` values with explicit Original, Committed Edit, Live Edit,
  and named-version representations. A missing source remains in its pane until it is replaced or
  the comparison is closed.
- Added transient `ComparisonSession` state for origin workspace, two sources, side-by-side,
  stacked, and single-pane layouts, focused pane, independent viewports, and lock/alignment state.
- Added browser selection resolution that requires exactly two supported images and preserves their
  visible order instead of relying on the unordered selection set.
- Added `ComparisonCoordinator` one-way transactions. Programmatic viewport changes carry a
  transaction identifier that is ignored when it echoes from the destination pane, preventing a
  synchronization feedback loop.
- Locked synchronization copies normalized displayed-image center, comparable source-pixel scale,
  and interpolation. Each pane clamps independently and the transaction reports when edge clamping
  makes an exact lock impossible.
- Temporary unlock preserves the saved normalized center offset and scale ratio. Alignment mode can
  save that relationship, and reset returns to equal center and scale.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/ComparisonSessionTests"
```

Result: 6 tests passed in 1 suite.

The comparison-foundation assertions cover:

- representation labels, missing-source retention, and replacement;
- exactly-two Browser entry ordering and unsupported selections;
- locked center, pixel-scale, and interpolation synchronization;
- independent clamping for mismatched landscape and portrait panes;
- alignment save, temporary unlock, relock, and reset; and
- suppression of out-of-order programmatic echoes without suppressing later user input.

## Manual validation

This slice contains no user-facing comparison surface, so visual, keyboard, and accessibility
validation are deferred to the side-by-side/stacked/A-B layout slice. That slice must visibly expose
pane focus, representation badges, lock state, and the inexact-lock/clamping indicator before its
delivery-plan item can close.

## Remaining Phase 7 work

- Build the side-by-side, stacked, and single-pane A/B surfaces with an adjustable divider.
- Connect Browser entry for exactly two images and implement replacement/navigation/deletion.
- Resolve source representations through a cancellable, memory-bounded render service.
- Add fit/100%/custom controls and visible focus, representation, and clamp badges.
- Validate two large RAW sources and decide the wipe/difference conditional gate.
