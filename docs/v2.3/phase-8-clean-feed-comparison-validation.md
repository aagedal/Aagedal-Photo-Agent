# Phase 8 — Clean Feed comparison validation

## Implemented behavior

- The comparison workspace publishes its immutable `ComparisonSession` and two completed render
  results to `CleanFeedController`; Clean Feed does not create a second coordinator or decode path.
- Focus, source replacement, representation labels, viewport changes, alignment changes, and
  missing-source state are republished after each atomic workspace mutation.
- Clean Feed renders side-by-side, stacked, or the currently focused pane through its existing
  16-bit Metal output surface. The output re-resolves `ViewportState` for the secondary display,
  retaining fit, actual-pixel/custom scale, normalized center, and HDR enablement semantics.
- The Clean Feed comparison layout is independent of the main workspace layout, selectable from
  the View menu, and persisted in `UserDefaults`.
- Closing or reloading Compare clears only the matching published session, preventing a late
  disappearing workspace from clearing a newer comparison.
- Focus changes continue to make the focused pane the single Browser selection. Rating and label
  menu commands therefore affect that image, and Compare now also supports the Browser's bare
  `0`–`5`, `6`–`9`, `X`, and `S` culling shortcuts.
- Settings now documents comparison navigation/culling shortcuts, full-screen `C`, and the Clean
  Feed toggle shortcut.

## Automated validation

Run on 2026-08-09:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/ComparisonCoordinatorTests'
```

Result: 24 tests passed. The suite includes odd-sized Clean Feed output geometry for side-by-side,
stacked, and focused-pane layouts, alongside the existing session mutation, focus, source
replacement, alignment, viewport synchronization, RAW cancellation, and render-budget coverage.
The test build compiles the AppKit/SwiftUI/Metal handoff under Swift 6 isolation.

## Manual release check still required

The delivery-plan item covering monitor disconnect/reconnect, HDR/SDR pairing, and sustained live
edit load remains open. Before the Phase 8 exit gate:

1. Connect an SDR secondary display, enable Clean Feed, and open Compare from Browser, Develop,
   and full-screen.
2. Select each View > Clean Feed Comparison Layout option and confirm the secondary display changes
   without changing the main comparison layout.
3. In focused-image output, switch focus with Tab and by clicking each main pane; verify the Clean
   Feed image and subsequent rating/label target follow focus.
4. At fit, 100%, and a panned custom zoom, verify output framing matches the comparison session for
   same- and mixed-aspect pairs.
5. Replace and delete focused sources, then close Compare; verify no stale comparison remains and
   browse/Develop Clean Feed content resumes.
6. Disconnect and reconnect the target monitor while each layout is active. Confirm teardown,
   fallback selection, and re-enable behavior leave no orphaned output window.
7. Repeat with SDR/SDR, HDR/HDR, and HDR/SDR pairs on an HDR-capable output; verify EDR engagement,
   black divider rendering, and no clipping or stale frames.
8. In Develop Compare, drag adjustments continuously for at least five minutes while watching
   memory, frame pacing, cancellation, and final-frame accuracy.
