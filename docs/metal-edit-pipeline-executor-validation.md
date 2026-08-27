# MetalEditPipeline executor validation — 2026-08-25

## Scope

This is bounded Phase 4.2 progress, not completion of the phase. It separates offscreen scheduling
and lifetime ownership from the live-preview facade and narrows worker-safe state publication without
changing shader behavior or startup/instrumentation code.

- Live preview and Clean Feed render state is owned by the main thread.
- The singleton offscreen/export pipeline and its queue are owned together by
  `OffscreenRendererExecutor`; `MetalEditPipeline.renderOffscreen*` are compatibility facades.
- Source-image upload and adjacent-image precaching remain worker-safe exceptions: source publication
  uses lock-backed `SourceState`, mirror lookup uses lock-backed `MirrorState`, the texture cache is
  `NSCache`, and their GPU work uses call-local command buffers/textures.
- White-balance reference writes remain owner-only; locked reads support the deliberately detached
  eyedropper solver. Temperature and tint are now captured as one atomic reference snapshot.

## Enforcement added

The live initializer now requires the main thread. The private offscreen initializer records the
serial-queue owner. A shared `preconditionOnStateExecutor()` guard is called before early returns at
the important mutable render-state boundaries: parameter/overlay upload, raster-mask rebuild and
incremental brush stamping, watermark refresh, live rendering, source clear/share/cache promotion,
and viewport/crop updates. Directly set live controls (gamut mode, mask previews, mirror wiring,
white-balance reference, and redraw callback) enforce the same contract.

`OffscreenRendererExecutor` owns serial submission and cancellation. Its synchronous facade asserts
that it was not called recursively on its own queue before a deadlock is possible; queued sync and
async work assert the executor on entry. The reusable pipeline records that exact queue in
`StateExecutor`, and `renderOffscreenSerial` independently checks it through
`preconditionOnStateExecutor()`.

`SourceState`, `MirrorState`, and `WhiteBalanceReference` replace five separate mutable
`nonisolated(unsafe)` fields. Source texture/orientation and white-balance temperature/tint now publish
and snapshot as coherent pairs. The remaining unsafe mutable render fields are owner-serialized and
still need a follow-up storage extraction before Phase 4.2 can be considered complete; immutable Metal
and Core Image resources remain documented unchecked framework references.

## Regression coverage

`BrushRasterizationTests.renderStateExecutorSourceContract` checks both owner kinds, live construction
enforcement, executor separation, sync re-entry and queue assertions, lock-backed publication state,
cross-pipeline owner checking, and the primary public render-state entry guards. The GPU rasterization
suite is main-actor isolated so its direct pipeline construction obeys the production live-instance
contract.

## Verification

- `xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS'
  -only-testing:'Aagedal Photo Agent Tests/BrushRasterizationTests'`
  — **passed**, 16 tests in 1 suite, 0 failures. This built the app and test targets under Swift 6.
- `xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS'
  -only-testing:'Aagedal Photo Agent Tests/BrushCompositingTests'`
  — **passed**, 10 tests in 1 suite, 0 failures. This exercised the shared offscreen queue owner.
- `xcodebuild build-for-testing -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS'
  -only-testing:'Aagedal Photo Agent Tests/BrushRasterizationTests'`
  — **passed** after the executor split under Swift 6.
- `git diff --check -- 'Aagedal Photo Agent/Services/MetalEditPipeline.swift'
  'Aagedal Photo Agent Tests/IPTCMetadataTests.swift' docs/app-improvement-audit-plan.md
  docs/metal-edit-pipeline-executor-validation.md` — **passed**, no whitespace errors.

The test host emitted pre-existing environment noise (`MDB_MAP_FULL` from its persistence store and a
SwiftUI background-publication warning); neither command reported a test failure or build warning tied
to MetalEditPipeline.
