# Plan-status Watermark import and Develop modal/geometry continuation — 2026-08-31

## Scope and checklist result

This continuation implemented one direct-filesystem slice from Phase 3.1 and two Develop state-owner slices
from Phase 4.1. Watermark PNG imports now cross a serialized asynchronous boundary, and named-version dialogs
plus mask/watermark interaction geometry have dedicated image-scoped owners. These changes advance broad open
gates rather than completing their remaining inventory, measurement, persistence, manual, or external work, so
the audit stays **63 of 75 checklist substeps complete**.

## Watermark library import boundary

`WatermarkLibraryImportService` now owns security-scoped source access, PNG reading and validation, and the
two-file library commit away from MainActor. It checks cancellation before access, before and after the read,
and before the commit; writes `image.png` before the discovery-boundary `meta.json`; compensates a failed
two-file commit by removing the incomplete item directory; and returns immutable durable-commit evidence when
cancellation arrives after installation.

`WatermarksLibraryView` owns request identity and a sequential batch-import task. Superseded or disappearing UI
cancels pending work and rejects stale selection/error presentation, while `WatermarkStore` still publishes every
durable commit. Store tests now inject an instance storage root instead of mutating the process-wide rendering
override, preventing cross-suite races once import began yielding asynchronously.

## Develop named-version dialog owner

`DevelopVersionDialogsCoordinator` owns create, rename, duplicate, delete, and Primary-promotion modal intent,
including draft names, typed action identity, presentation bindings, consume-once confirmation, cancellation,
and image-replacement reset. `EditWorkspaceView` no longer retains four independent named-version modal fields;
the existing named-version catalog and persistence commits remain injected at the view boundary.

## Develop layer-geometry owner

`DevelopLayerGeometryInteractionCoordinator` owns image-scoped mask-drag state and transient mask/watermark
geometry. Handle and inspector interactions update render-only overrides, then consume the final geometry exactly
once at the existing persistence boundary. Image replacement and workspace teardown clear every transient value,
and `EditWorkspaceView` no longer retains separate mask-drag or geometry state.

## Validation

The initial two focused selections passed **45 tests** across the new coordinator/import coverage and adjacent
Develop interaction and watermark-rendering suites. A combined affected-suite regression then passed all **18
tests** across `WatermarkStoreTests`, `WatermarkLibraryImportServiceTests`, `WatermarkRenderingTests`, and
`DevelopInteractiveRenderCoordinatorTests`.

The first full parallel run exposed two test-harness assumptions rather than application failures: the yielding
import test shared a process-wide storage override with watermark rendering, and the interactive-render throttle
test used a five-second wall-clock deadline while MainActor was saturated. Instance-injected storage removed the
cross-suite race, and an injected throttle-delay boundary made the coalescing assertion scheduler-independent.
The final unfiltered current-source gate passed **1,804 tests in 212 suites** in 40.154 seconds. Its result bundle
is `/private/tmp/aagedal-v3-session-derived/Logs/Test/Test-Aagedal Photo Agent
Tests-2026.08.31_00-37-42-+0200.xcresult`.

The complete `scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata,
JSON/plist/project validation, bundled artifact provenance, unified-log and investigation privacy checks,
conflict scanning, and whitespace validation before the final documentation update; the gate was rerun after
that update as recorded in this session's handoff.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 retains lower-priority direct filesystem paths and
its local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread
Performance Checker exit evidence. Phase 4.1 retains broader metadata/sidecar persistence routing and remaining
Develop view decomposition even though the named-version modal and mask/watermark geometry ownership called out
by the previous checkpoint are now complete.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
