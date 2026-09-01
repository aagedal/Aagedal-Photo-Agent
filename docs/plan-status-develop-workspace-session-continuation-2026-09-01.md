# Plan-status Develop workspace-session continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by moving Develop state whose lifetime is
the complete workspace presentation out of `EditWorkspaceView` and into an independently testable coordinator.
It also removes a redundant Core Image preview-publication slot. It does not complete the broad Phase 4.1
extraction gate, so the audit remains at 63 of 75 completed substeps.

## Workspace-session ownership

`DevelopWorkspaceSessionCoordinator` now owns the external named-version flush registration for one Develop
workspace presentation. Appearance installs exactly one registration, repeated appearance replaces the complete
session defensively, and disappearance unregisters the exact token before rejecting further workspace notices.
The registration survives image navigation because its lifetime is explicitly separate from the image-scoped
decode, crop, layer, version, and persistence coordinators.

The same coordinator owns transient copy, paste, and template feedback. A replacement notice cancels the prior
timer and advances an identity token, preventing an already-resumed older timer from clearing newer feedback.
Workspace teardown cancels the timer, clears the notice, and rejects late publication. `EditWorkspaceView` now
renders this coordinator's notice and delegates begin, end, and feedback operations instead of keeping raw
registration, message, and unstructured task state.

## Single materialized-preview publication owner

The view's private `previewCIImage` state was never assigned a non-`nil` value, but it still presented a second
apparent publication route beside `DevelopPreviewRenderCoordinator`. That redundant slot and its reset writes
are removed. The Core Image fallback receives the retained source image; the Metal pipeline remains the owner of
interactive adjustments, and `DevelopPreviewRenderCoordinator.previewImage` remains the sole materialized AppKit
preview publication owner. This preserves the existing rendered behavior while making the ownership boundary
explicit.

## Characterization and validation

Five workspace-session characterizations cover flush-registration lifetime, notice replacement, teardown, a
repeated workspace begin, and view delegation. A preview source contract rejects reintroduction of the redundant
Core Image publication state.

- Focused workspace-session and preview-publication selection: 10 tests in 2 suites passed.
- Adjacent workspace input, version catalog/session, preview publication, and render-policy selection: 42 tests
  in 6 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,871 tests in 219 suites passed in 61.519 seconds.
- Result bundle:
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_20-35-14-+0200.xcresult`.

The test host emitted its existing App Intents, iCloud entitlement, LMDB cache-capacity, synthetic-file,
background-publication, XMP, and platform image/codec diagnostics. None failed the focused, adjacent, or
unfiltered gates and none originated in this workspace-session extraction.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs further `EditWorkspaceView` decomposition before the
major-feature ownership exit gate can be claimed, including remaining adjustment and presentation orchestration.
Phase 3.1 remains open for lower-priority direct filesystem paths plus local SSD, network, iCloud-placeholder,
read-only, large-library, signpost, and Thread Performance Checker evidence. The real RAW/HDR Instruments
benchmark remains open in Phase 3.2.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
