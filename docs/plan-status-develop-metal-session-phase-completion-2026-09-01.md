# Plan-status Develop Metal-session and Phase 4.1 completion — 2026-09-01

## Scope and checklist result

This continuation completes Phase 4.1 of the v3 app-improvement audit. The final major renderer-lifetime state
has moved out of `EditWorkspaceView` into an independently testable coordinator, and a current inventory confirms
that every remaining major Develop feature state has one named owner. The three remaining Phase 4.1 substeps are
therefore complete, advancing the audit from 63 of 75 to 66 of 75 completed substeps, with nine remaining.

## Metal-preview session ownership

`DevelopMetalPreviewSessionCoordinator` now owns creation and one-time warmup of the expensive live-preview
pipeline, its `MetalPreviewView.Coordinator`, workspace and source-image presentation identity, continuous-render
state, redraw requests, and teardown. The warmed pipeline is retained across appearances of the same SwiftUI view
identity, while each image session resets its generation, matte, as-shot white balance, and overlay state. A
same-image rotation advances source-publication identity without clearing the valid fallback texture.

Workspace and image shutdown clear source texture, matte, overlays, and continuous rendering through the same
owner. Image/publication starts, continuous-render starts, and redraw requests made outside an active workspace
are inert. `EditWorkspaceView` now delegates those transitions to the coordinator; its transitional computed
accessors expose the pipeline and view coordinator to existing render commands without reintroducing state
ownership.

## Phase 4.1 ownership inventory

The Develop view's major `@State` values are now named owners for interactive rendering, materialized preview,
Clean Feed, comparison, versions and dialogs, decoded source publication, export, crop, workspace input and
notices, transient comparison, section mutes, persistence, Metal preview, layers and local geometry, LUT import,
navigation, white balance, mask interaction, and AI mask generation. `WatermarkStore` remains its own shared
owner. The few direct values left in the view are presentation or framework-local state: an alert flag, pane
frame, HDR hover state, focus/observed scaling, and cursor readout state in a nested helper view.

Each extracted owner defines the lifetime relevant to its feature, exposes injected or typed mutation seams, and
has focused lifecycle and stale-result characterizations. Persistence owners keep durable writers injected;
decode and renderer owners return or publish immutable results through identity gates; workspace teardown rejects
late UI publication without cancelling writes that may already be partially committed. The scene-scoped typed
`AppCommand` router was completed previously. Together these boundaries satisfy the Phase 4.1 exit gate without
requiring presentation-only SwiftUI state to become artificial coordinators.

## Characterization and validation

Four new Metal-session characterizations cover lazy factory invocation, generation replacement,
inactive-workspace rejection, continuous-render lifecycle, idempotent teardown, and view delegation. Existing
source contracts were updated to reject raw pipeline ownership and to inventory the new facade.

- Focused Metal-session/source-publication selection: 14 tests in 3 suites passed.
- Adjacent preview lifecycle and rendering-owner selection: 37 tests in 8 suites passed.
- Focused render-state facade contract after its ownership inventory update: 16 tests in 1 suite passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,875 tests in 220 suites passed in 75.125 seconds.
- Result bundle:
  `/tmp/AagedalPhotoAgent-v3-metal-session/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_20-58-04-+0200.xcresult`.

The authoritative runs used an isolated Derived Data directory because an unrelated Xcode process held the
shared build database lock. The test host emitted its existing App Intents, LMDB cache-capacity, synthetic-file,
background-publication, XMP, and platform image/codec diagnostics. None failed the focused, adjacent, or
unfiltered gates and none originated in this extraction.

## Remaining boundary after this session

Nine audit substeps remain open. Phase 3.1 still needs completion of the broad filesystem-boundary conversion and
real local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread
Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The remaining manual and external gates are protected-release-branch enforcement, focused Known People
privacy/legal review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and production
AuraFace artifact publishing plus clean-install/offline/update/rollback/corrupt-download validation.
