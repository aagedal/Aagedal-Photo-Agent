# Phase 7 comparison core — validation note

## Implemented foundation

The first Phase 7 slice adds UI-independent comparison state and coordination:

- exact-revision-bound left and right sources;
- Original, Committed Edit, Live Edit, and named-version representations;
- side-by-side, stacked, and single-pane layout state;
- focused pane, origin workspace, source replacement, and missing-source survival;
- locked, temporarily unlocked, and anchored alignment states;
- normalized center offset and right-to-left pixel-scale ratio;
- one-way viewport transactions with independent edge clamping and tagged callback suppression;
- explicit HDR/SDR mismatch state.

The coordinator computes a complete candidate session before committing it. Missing or invalid
geometry therefore leaves the previous session unchanged. A follower clamped by a different aspect
ratio is never allowed to drive a reverse update into the original pane.

## Automated validation

`ComparisonCoordinatorTests` covers:

- normalized center and comparable custom-scale synchronization;
- mismatched aspect ratios and independent follower clamping;
- feedback callback suppression using transaction identifiers;
- alignment offset and scale-ratio capture;
- temporary unlock and re-lock without losing alignment;
- explicit alignment reset;
- missing-source survival and replacement;
- representation labels and HDR/SDR mismatch detection;
- invalid alignment rejection and atomic failure behavior.

Run with:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/ComparisonCoordinatorTests"
```

## Manual validation status

The Browser now exposes Compare for exactly two supported, visible selected images. The surface
provides draggable side-by-side and stacked splitters, single-pane A/B switching, pane focus,
representation and dynamic-range badges, Fit/100%/custom scale, linked pan/zoom, temporary unlock,
saved alignment offset, edge-clamp disclosure, cancellation, and accessible pane labels.

Left/Right Arrow or the toolbar replaces the focused pane in visible filmstrip order while keeping
the session viewport and alignment. Replacement skips the source already shown in the other pane,
uses the same cancellable revision capture and bounded render path as initial loading, and stops at
filmstrip boundaries. Tab changes pane focus. Delete targets only the focused image and reuses the
Browser's confirmation-based Trash flow. If a compared source disappears, the session retains the
surviving pane, moves focus safely, and offers the nearest distinct survivor from the pre-deletion
order. Closing Compare restores the current surviving comparison sources as the Browser selection.

The resolver tests additionally cover visible-order navigation, duplicate-source avoidance,
boundary behavior, and nearest-survivor replacement after deletion.

The comparison renderer captures exact source revisions before presentation and reuses the bounded
full-screen caches and committed-edit decode path. Two-RAW memory measurement and the complete
keyboard/VoiceOver pass remain pending.
