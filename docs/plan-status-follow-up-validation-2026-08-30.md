# Plan status follow-up validation — 2026-08-30

## Sidebar drop filesystem boundary

Sidebar drag-and-drop no longer calls `FileManager.fileExists` for every dropped URL from its inherited
main-actor task. `FileSystemService` now freezes dropped URLs into one immutable snapshot of directories,
regular files, and missing items on its serialized actor. Cancellation is checked before and between probes;
a pre-cancelled request performs no probe and publishes no partial classification. Existing favorite-folder
reordering, folder moves, image moves, and missing-item behavior remain unchanged.

Three new characterizations cover exact input classification, off-main execution, and pre-cancellation with
zero probes. This advances Phase 3.1, but lower-priority direct paths and the slow-volume/signpost/benchmark
exit gate remain open.

## Delivery Receipt summary export hardening

The existing exclusive-create receipt-summary actor now has an injected, testable writer and a Sendable
export protocol. The actor still refuses overwrite, serializes synchronous commits off the main actor, and
returns immutable byte-count and destination evidence. Queued cancellation is explicit and writes nothing;
cancellation arriving during a completed synchronous write is reported on the durable commit instead of
misreporting the file as absent.

`DeliveryReceiptLibraryModel` now gates its shared error state by export generation. A late failure from a
superseded export cannot replace the newer operation's successful UI state. Four additional tests cover
off-main serialization, queued cancellation, cancellation after commit, and stale-failure suppression. The
complete Activity-library suite contains 11 passing tests.

## Develop preview-session state owner

`DevelopPreviewSessionCoordinator` is now the named owner for Develop source URL/orientation identity,
preview/full-resolution progress, and the source-load, preview-render, adjacent-RAW-precache, and
full-resolution-upgrade task lifecycles. Beginning another image session cancels all four producer families
and resets image-scoped progress together. Workspace teardown now crosses the same boundary, including the
previously separate full-resolution upgrade task. In-place rotation updates the retained orientation only
when it belongs to the active decoded image. A monotonically increasing session generation also prevents a
cancelled A-session completion from clearing the task handle after an A→B→A navigation cycle.

Two characterization tests prove replacement-image cancellation/reset and source-identity-gated orientation.
The view remains responsible for decode, Metal publication, and visible UI state, so broader Develop render
ownership and the Phase 4.1 extraction exit gate remain open.

## Metal brush-raster state isolation

Four mutable `MetalEditPipeline` fields—brush alpha texture, stroke-envelope scratch texture, last raster
sources, and last raster size—now live in `ExecutorOwnedBrushRasterState`. Snapshot and update accessors
enforce the pipeline's selected state executor. Rebuild publishes both textures as one generation, while
clear and refresh replace texture/cache-key state coherently.

The source contract requires the new holder and checked accessors, rejects the four former unsafe stored
properties, and lowers the explicit `nonisolated(unsafe)` ceiling from 8 to 4. Remaining escapes are the
immutable Metal texture-cache payload, `NSCache`, image-memory registration, and render-log width. The
compile-time live-preview facade also remains open.

## Investigation privacy validator reconciliation

The repository privacy gate still expected Analysis reports to write atomically inside
`AnalysisWorkspaceView`, although the earlier async-boundary continuation intentionally moved all report and
evidence commits into `AnalysisExportFileService`. The invariant now checks the serialized service's injected
system writer for `.atomic` installation, and its self-test includes a fail-closed mutation that removes that
option. The validator passes all 22 reviewed invariants and its positive-plus-five-regression self-test.

## Integrated validation

A stable `xcodebuild test` compiled the complete application and unit-test targets, then passed all **43
tests in 4 suites**:

- `SerializedFileSystemServiceTests` (14);
- `DeliveryReceiptLibraryModelTests` (11);
- `DevelopPreviewSessionCoordinatorTests` (2); and
- `BrushRasterizationTests` (16).

The result was `** TEST SUCCEEDED **`; the preserved result bundle is:

```text
/private/tmp/aagedal-v3-20260830-drop/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_00-33-26-+0200.xcresult
```

The host emitted the previously documented App Intents metadata and LMDB map-size diagnostics. They did not
produce a build failure, test issue, cancelled test, or failure in the 43 selected tests. `git diff --check`
also passed. The complete `scripts/ci/validate_repository.sh` gate then passed generated-document checks,
release metadata, JSON/plist/project validation, bundled-component provenance, logger and investigation
privacy checks, conflict-marker scanning, and whitespace validation.

## Remaining boundary after this session

The audit remains **61 of 75 checklist substeps complete**. These four bounded slices advance the broad Phase
3.1, Phase 4.1, and Phase 4.2 items without satisfying their full exit gates. Automated implementation still
includes lower-priority direct filesystem paths, broader Develop/render coordinator extraction, a compile-time
live-preview facade, and isolation or written invariants for the final four Metal unsafe escapes. Manual and
external work still includes slow-volume and Thread Performance Checker evidence, Instruments memory
benchmarks, menu/shortcut/focus/multi-window and accessibility passes, protected release-branch configuration,
focused privacy/legal review, real FTP/FTPS/SFTP drills, and production AuraFace publishing and supported-macOS
validation.
