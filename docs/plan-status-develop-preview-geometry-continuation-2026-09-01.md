# Plan-status Develop preview-geometry continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by moving Develop preview geometry into the
coordinator that already owns the zoom and pan values from which that geometry is derived. It does not complete
the broad Phase 4.1 extraction gate, so the audit remains at 63 of 75 completed substeps.

## Coordinator-owned preview geometry

`DevelopPreviewNavigationCoordinator` now returns one immutable `DevelopPreviewViewport` containing the paired
origin and size consumed by Metal and the Core Image fallback. It owns the calculations for:

- normal fit/letterbox viewports at the current zoom and pan;
- confirmed-crop viewports, including conversion of view-space pan through crop-straighten rotation;
- normal and confirmed-crop cursor-anchored zoom transitions;
- full-source framing around an upright crop for both crop-tool and confirmed-crop presentation;
- normal fit-view pan limits; and
- confirmed-crop pan limits derived from the same crop framing used for display.

Invalid or empty geometry returns explicit inert identity/zero results. The view retains UI layout and final Metal
publication but no longer defines its own crop-viewport type or repeats the viewport, crop-fit, rotation, and
zoom-anchor, and pan-bound formulas. Two unused private fit helpers were removed with the extracted calculation
block, reducing `EditWorkspaceView.swift` from 8,624 to 8,352 lines without changing the visible interaction
contract.

## Characterization and validation

Seven new characterizations prove normal letterbox/pan projection, rotated cropped-view pan projection, normal
and cropped cursor anchoring, shared crop framing and pan-limit geometry, invalid-size fallback behavior, and
delegation from the Develop view.

- Focused navigation selection: 12 tests in 1 suite passed.
- Adjacent Develop interaction, crop, and navigation selection: 41 tests in 3 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,856 tests in 217 suites passed in 61.607 seconds.
- Result bundle:
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_20-03-40-+0200.xcresult`.

The test host emitted its existing App Intents, LMDB cache-capacity, invalid-fixture decode, and other expected
diagnostic warnings. None failed the focused, adjacent, repository, or unfiltered gates, and none originated in
this geometry change.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs mask/watermark geometry, broader render-policy, and view-
decomposition ownership before the major-feature exit gate can be claimed. Phase 3.1 remains open for lower-
priority direct filesystem paths plus local SSD, network, iCloud-placeholder, read-only, large-library, signpost,
and Thread Performance Checker evidence. The real RAW/HDR Instruments benchmark remains open in Phase 3.2.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
