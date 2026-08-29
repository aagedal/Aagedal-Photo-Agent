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

## Develop single-image export directory boundary

Develop's single-image Save action no longer creates its `Edited` destination with synchronous
`FileManager` work in the inherited main-actor task. It awaits the existing serialized
`ExportDirectoryService` and consumes its immutable commit evidence before starting the detached render.
Pre-commit cancellation creates no directory. If cancellation arrives during the non-preemptible directory
creation, the durable empty directory remains while the expensive render is suppressed; cancellation is not
presented as a save failure.

A focused source-contract characterization keeps this specific UI path on the serialized service, requires
the durable-after-cancel branch and a final cancellation check before rendering, and rejects a regression to
direct directory creation. The existing service characterizations continue to cover off-main execution,
pre-cancellation with no mutation, queued cancellation, serialization, and cancellation after a durable
commit. This advances Phase 3.1 without completing its broader filesystem inventory or measurement gates.

An isolated focused `xcodebuild test` compiled the complete application and unit-test targets, then passed
all **5 tests** in `ExportDirectoryServiceTests`, including the new Develop-path contract. The result was
`** TEST SUCCEEDED **`; the preserved result bundle is:

```text
/private/tmp/aagedal-v3-single-save-20260830-2.xcresult
```

The host emitted the previously documented App Intents metadata, LMDB map-size, detached-signature, and
background-publication diagnostics. They did not produce a build failure or test issue.

## Content-area folder-drop boundary

The main content drop target no longer calls `FileManager.fileExists` from the item-provider callback. Each
provider URL is classified by `FileSystemService.dropSourceSnapshot`; only the immutable directory result is
then handed back to the main actor for folder loading. This reuses the sidebar drop boundary's existing
off-main, input-order, missing-item, and pre-cancellation behavior.

A focused source contract rejects direct existence probing in `ContentView.handleDrop` and requires the
serialized classification call before folder loading. This removes another lower-priority direct filesystem
path while leaving the broader slow-volume and measurement exit gate open.

## Final Metal unsafe-escape isolation

The final four explicit `nonisolated(unsafe)` declarations in `MetalEditPipeline` are gone. Render-log width
is part of the executor-owned live-state generation, so its read/update is checked against the live main
thread or dedicated offscreen render queue like the other mutable render state. Speculative `NSCache`
storage and the `ImageMemoryCoordinator.Registration` now share one lock-backed lifetime holder. Every cache
limit change, eviction, insertion, and promotion crosses that holder; registration is installed exactly once
and is released with the cache owner.

The memory-pressure generation gate now stays locked across final cache publication. This closes the former
check-then-insert interval in which pressure could cancel and evict a completed precache immediately before
that worker repopulated the cache. The remaining unchecked boundary is type-level and documented:
`MTLTextureWrapper` carries a fully rendered, mip-complete Metal handle across the worker/cache boundary, and
the texture contents are immutable while cached. Stable pipeline resource handles retain their existing
executor-checked content-mutation invariant.

The focused source contract requires zero explicit `nonisolated(unsafe)` occurrences, the executor-owned
render-log field, the lock-backed cache/registration holder, its one-shot registration, the atomic generation
commit, and the immutable cached-texture invariant. This completes the Phase 4.2 unsafe-state reduction
substep, but does not claim the separate compile-time live-preview facade or the broader Phase 4.2 exit gate.

A clean focused test built the complete application and unit-test targets, then passed all **23 tests in 2
suites**:

- `BrushRasterizationTests` (16), including the strengthened source contract;
- `ImageMemoryCoordinatorTests` (7), including memory-pressure cancellation/eviction and speculative-cache
  suppression.

```text
xcodebuild test -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/aagedal-v3-metal-final CODE_SIGNING_ALLOWED=NO \
  -only-testing:"Aagedal Photo Agent Tests/BrushRasterizationTests" \
  -only-testing:"Aagedal Photo Agent Tests/ImageMemoryCoordinatorTests"
** TEST SUCCEEDED **
```

The result bundle is:

```text
/private/tmp/aagedal-v3-metal-final/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_00-43-30-+0200.xcresult
```

The same current-source build then passed all **15 tests** in `SerializedFileSystemServiceTests`, including
the concurrent content-area folder-drop source contract:

```text
xcodebuild test-without-building -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/aagedal-v3-metal-final CODE_SIGNING_ALLOWED=NO \
  -only-testing:"Aagedal Photo Agent Tests/SerializedFileSystemServiceTests"
** TEST EXECUTE SUCCEEDED **
```

Its result bundle is:

```text
/private/tmp/aagedal-v3-metal-final/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_00-46-43-+0200.xcresult
```

The existing preview/Clean Feed/offscreen export/cancellation/navigation overlap characterization also
passed from the same build. This invocation did not enable Thread Sanitizer and therefore supplements rather
than replaces the separately documented TSAN procedure:

```text
xcodebuild test-without-building -project "Aagedal Photo Agent.xcodeproj" \
  -scheme "Aagedal Photo Agent Tests" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/aagedal-v3-metal-final CODE_SIGNING_ALLOWED=NO \
  -only-testing:"Aagedal Photo Agent Tests/MetalPipelineTSANStressTests"
** TEST EXECUTE SUCCEEDED ** — 1 test in 1 suite
```

```text
/private/tmp/aagedal-v3-metal-final/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_00-47-31-+0200.xcresult
```

The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature, and SwiftUI
background-publication diagnostics. They did not produce a build failure, test issue, cancellation, or test
failure. `git diff --check` also passed.

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

The audit is now **62 of 75 checklist substeps complete**. These seven bounded slices advance the broad Phase
3.1, Phase 4.1, and Phase 4.2 items without satisfying their full exit gates. Automated implementation still
includes lower-priority direct filesystem paths, broader Develop/render coordinator extraction, a compile-time
live-preview facade, and continued enforcement of the audited Metal unchecked-Sendable invariants. Manual and
external work still includes slow-volume and Thread Performance Checker evidence, Instruments memory
benchmarks, menu/shortcut/focus/multi-window and accessibility passes, protected release-branch configuration,
focused privacy/legal review, real FTP/FTPS/SFTP drills, and production AuraFace publishing and supported-macOS
validation.
