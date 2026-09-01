# Plan-status Develop layer-geometry continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by moving the remaining mask and watermark
interaction-coordinate policy out of `EditWorkspaceView` and into the coordinator that already owns those
layers' image-scoped transient geometry. It does not complete the broad Phase 4.1 extraction gate, so the audit
remains at 63 of 75 completed substeps.

## Coordinator-owned layer projection

`DevelopLayerGeometryInteractionCoordinator` now consumes one immutable `DevelopLayerGeometryProjection`
snapshot containing the current EXIF orientation, display-image size, crop, straighten angle, and preview zoom.
It owns:

- preview-pane point to display-UV mapping, including letterbox rejection;
- ellipse-mask sensor/display conversion through EXIF orientation and crop straighten;
- watermark-anchor sensor/display conversion, with explicit straighten inclusion for normal versus confirmed-
  crop presentation;
- brush-stroke display-to-sensor orientation conversion;
- AI-mask click projection back into the un-straightened Vision source frame;
- confirmed-crop watermark image size and overlay content framing; and
- watermark position reclamping after size, unit, or margin changes, using the normal or confirmed-crop frame.

The coordinator continues to own mask/watermark drag overrides, image-session cancellation, and consume-once
commit values. `EditWorkspaceView` supplies current presentation facts and retains UI layout, live Metal updates,
and XMP/named-version commit injection. It no longer defines the projection, rotation, crop-frame, or reclamping
formulas. Existing brush behavior deliberately remains EXIF-only; applying crop straighten to brush dabs is a
separate previously documented edge case and was not silently changed by this extraction.

## Characterization and validation

Four new characterizations cover mask and watermark EXIF/straighten round trips, confirmed-crop watermark
framing, crop-relative size/margin reclamping, and shared brush/AI projection. Together with the two existing
transient-lifecycle tests and a strengthened view-delegation contract, the focused coordinator suite contains
seven tests.

- Focused layer-geometry selection: 7 tests in 1 suite passed.
- Adjacent interaction, crop, ellipse orientation/straighten, brush XMP, and Watermark Metal selection: 56 tests
  in 7 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,860 tests in 217 suites passed in 63.287 seconds.
- Result bundle:
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_20-12-12-+0200.xcresult`.

The test host emitted its existing App Intents, iCloud entitlement, LMDB cache-capacity, missing synthetic image,
and background-publication diagnostics. None failed the focused or adjacent gates and none originated in this
geometry extraction.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs broader render-policy ownership and further view
decomposition before the major-feature exit gate can be claimed. Phase 3.1 remains open for lower-priority direct
filesystem paths plus local SSD, network, iCloud-placeholder, read-only, large-library, signpost, and Thread
Performance Checker evidence. The real RAW/HDR Instruments benchmark remains open in Phase 3.2.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
