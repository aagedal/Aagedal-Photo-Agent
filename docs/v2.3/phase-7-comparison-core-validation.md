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

No comparison surface is exposed in this slice, so visual, keyboard, accessibility, RAW-memory,
and source-navigation checks remain pending. Those checks become meaningful after the comparison
render service, layouts, and Browser entry are wired in the next Phase 7 slices.
