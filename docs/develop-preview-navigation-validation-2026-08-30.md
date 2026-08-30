# Develop preview navigation state-owner validation — 2026-08-30

## Scope

This Phase 4.1 continuation extracts one bounded state cluster from `EditWorkspaceView`.
`DevelopPreviewNavigationCoordinator` is now the named owner of the normal Develop preview's live
and committed zoom scale and pan offset. Crop-tool framing remains intentionally separate.

The view still owns preview geometry, cursor-to-image mapping, crop geometry, gesture surfaces,
and Metal viewport publication. Scroll zoom, the keyboard 1:1 toggle, trackpad magnification,
normal drag panning, and hold-Space hand-tool panning now mutate navigation state only through the
coordinator. Image/source resets clear the complete navigation session through the same owner.

## Preserved behavior

- Trackpad magnification keeps the existing `0.4` dampening and shared `1...40` zoom bounds.
- A return to fit recenters both live and committed pan anchors.
- Cursor-anchored zoom calculations remain in the view and publish their result atomically through
  the coordinator before the existing geometry clamp.
- Pan updates remain relative to the preceding completed gesture, and completion clamps both the
  displayed offset and the next gesture anchor to the same bounds.
- Pan gesture cleanup uses a dedicated `recenter()` transition that does not alter zoom state.
- Crop-tool zoom (`cropZoomScale` and `lastCropZoomScale`) is unchanged.

## Characterization coverage

`DevelopPreviewNavigationCoordinatorTests` adds five deterministic characterizations covering:

1. dampening, committed-scale anchoring, and maximum zoom;
2. fit-view recentering and rejection of pan input at fit;
3. committed pan anchoring and symmetric bounds clamping;
4. complete image-session reset; and
5. gesture recentering that preserves zoom.

## Validation

The integrated current-source build succeeded, and the focused navigation suite passed all five
tests as part of the combined touched selection:

```text
xcodebuild test-without-building -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/aagedal-v3-responsiveness CODE_SIGNING_ALLOWED=NO \
  -only-testing:"Aagedal Photo Agent Tests/DevelopPreviewNavigationCoordinatorTests"
```

The four combined touched suites passed **18 tests**, and the subsequent unfiltered run passed
**1,626 tests in 185 suites**. The focused result bundle is:

```text
/tmp/aagedal-v3-responsiveness/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_10-19-22-+0200.xcresult
```

## Remaining Phase 4.1 boundary

This is one additional state owner, not the Phase 4.1 exit gate. `EditWorkspaceView` still owns
large independent clusters including crop interactions, layer selection/reordering, transient mute
state, white-balance picking, and export presentation. Further slices should continue to preserve
geometry and render publication at explicit boundaries while moving coherent mutable lifecycles to
testable owners.
