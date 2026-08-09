# Phase 8 — full-screen comparison validation

## Implemented behavior

- The dedicated full-screen viewer exposes an accessible **Compare** control and the `C` shortcut
  when another supported image is available.
- Pane A is the image actually active in full-screen. Pane B prefers another selected image in
  visible Browser order, then the next supported filmstrip image, then the previous image at the
  end of the filmstrip.
- Pane A preserves the full-screen **Viewing edits** / **Viewing original** choice, uses the
  matching edited/original cache namespace, and carries the corresponding representation badge.
- The comparison pair is frozen before dismissal, but the comparison workspace is not constructed
  until `FullScreenPresenter` has ordered out and released its always-on-top window.
- The resulting `ComparisonSession` records `.fullScreen` as its origin and otherwise uses the same
  viewport, layout, replacement, and missing-source semantics as Browser and Develop Compare.
- Escape or **Close Compare** preserves the focused comparison source, removes the comparison
  workspace, yields one main-actor turn, and then recreates the dedicated full-screen window. This
  avoids overlapping key windows and restores keyboard focus to full-screen.
- With no valid peer image, the Compare control and shortcut hint are absent and bare `C` is not
  intercepted.

## Automated validation

Run on 2026-08-09:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/ComparisonCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/FullScreenShortcutTests'
```

Result: 26 tests passed. The comparison resolver tests cover selected-peer priority, next-neighbor
selection, unsupported-file skipping, previous-neighbor boundary fallback, and the no-peer state.
Representation routing verifies that Original and edited views use distinct pixel-cache paths. The
build also compiles the AppKit/SwiftUI presenter handoff under Swift 6 isolation.

## Manual release check

Before the Phase 8 exit gate:

1. Open full-screen on the first, middle, and last supported image in a mixed-format folder.
2. Use both the Compare button and `C`; verify the displayed image remains A and the expected peer
   becomes B.
3. Pan/zoom, switch layouts, change focus with Tab, and replace the focused source with arrow keys.
4. Press Escape and use **Close Compare**. Verify Compare disappears before full-screen returns,
   the focused source is shown, and arrows/Space/rating shortcuts work immediately.
5. Repeat entry and exit quickly ten times and confirm no orphaned black window, stuck menu focus,
   duplicate key-event handling, or decode task remains.
6. Repeat with only one supported image visible and verify Compare is unavailable while ordinary
   full-screen shortcuts continue to work.
