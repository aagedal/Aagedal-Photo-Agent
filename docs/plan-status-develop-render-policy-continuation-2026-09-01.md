# Plan-status Develop render-policy continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by moving Develop preview dispatch and
gamut-selection policy out of `EditWorkspaceView` and into an independently testable value coordinator. It does
not complete the broad Phase 4.1 extraction gate, so the audit remains at 63 of 75 completed substeps.

## Coordinator-owned render policy

`DevelopRenderPolicyCoordinator` now consumes one immutable `DevelopRenderPolicyInput` and selects the exact
work path for a preview refresh:

- publish the retained `NSImage` fallback when no Core Image source exists;
- rely on continuous Metal scopes during an active slider gesture;
- request the throttled CPU-scope fallback when no Metal scope pipeline exists;
- keep crop interaction on the full-resolution Metal path without materializing a competing CG image; or
- materialize the settled Core Image result for preview and scope publication.

The same decision records whether comparison rendering, scope-crop synchronization, Metal parameter updates,
viewport synchronization, overlay clearing, and Metal-scope redraw are required. The coordinator also owns the
SDR/HDR display-gamut selection and the exact disabled/one-based gamut-clipping shader mapping.

`EditWorkspaceView` supplies current source, interaction, Metal, crop, and comparison facts, then performs the
selected effects through the existing owners. Source decode remains in `DevelopSourceDecodeService`; Metal
mutation remains in `MetalEditPipeline`; materialized-preview lifetime remains in
`DevelopPreviewRenderCoordinator`; high-frequency scope lifetime remains in
`DevelopInteractiveRenderCoordinator`; and comparison and Clean Feed publication retain their existing owners.
The extraction therefore changes policy ownership without merging pixel or cancellation lifetimes.

## Characterization and validation

Five new characterizations cover missing-source fallback, Metal-versus-CPU interactive scopes, crop-versus-
materialized settled rendering, all SDR/HDR and clipping-gamut mappings, and view delegation.

- Focused render-policy, preview-publication, and interactive-render selection: 14 tests in 3 suites passed.
- Adjacent render, transient/section mute, crop, comparison, Clean Feed, and Metal-publication selection: 36
  tests in 9 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,865 tests in 218 suites passed in 60.654 seconds.
- Result bundle:
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_20-21-18-+0200.xcresult`.

The test host emitted its existing App Intents, iCloud entitlement, LMDB cache-capacity, synthetic-file,
background-publication, and platform image/codec diagnostics. None failed the focused, adjacent, or unfiltered
gates and none originated in this policy extraction.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs further `EditWorkspaceView` decomposition before the
major-feature ownership exit gate can be claimed; concrete pixel work intentionally remains in its specialized
decode, Metal, materialization, scope, comparison, and publication owners rather than being combined with the
new dispatch policy. Phase 3.1 remains open for lower-priority direct filesystem paths plus local SSD, network,
iCloud-placeholder, read-only, large-library, signpost, and Thread Performance Checker evidence. The real RAW/HDR
Instruments benchmark remains open in Phase 3.2.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
