# MetalEditPipeline executor validation — 2026-08-25

## Scope

This is bounded Phase 4.2 progress, not completion of the phase. It adds runtime enforcement to the
existing ownership model without splitting the pipeline or changing startup/instrumentation code.

- Live preview and Clean Feed render state is owned by the main thread.
- The singleton offscreen/export pipeline is owned by `offscreenRenderQueue`.
- Source-image upload and adjacent-image precaching remain worker-safe exceptions: source publication
  uses `sourceTextureLock`, mirror lookup is locked, the texture cache is `NSCache`, and their GPU work
  uses call-local command buffers/textures.
- White-balance reference writes remain owner-only; locked reads support the deliberately detached
  eyedropper solver.

## Enforcement added

The live initializer now requires the main thread. The private offscreen initializer records the
serial-queue owner. A shared `preconditionOnStateExecutor()` guard is called before early returns at
the important mutable render-state boundaries: parameter/overlay upload, raster-mask rebuild and
incremental brush stamping, watermark refresh, live rendering, source clear/share/cache promotion,
and viewport/crop updates. Directly set live controls (gamut mode, mask previews, mirror wiring,
white-balance reference, and redraw callback) enforce the same contract.

`renderOffscreenSerial` independently asserts `offscreenRenderQueue`, protecting the contract even if
a future internal caller bypasses the public sync/async wrappers.

## Regression coverage

`BrushRasterizationTests.renderStateExecutorSourceContract` checks that both owner kinds, live
construction enforcement, both offscreen queue assertions, and the primary public render-state entry
guards remain in source. The GPU rasterization suite is main-actor isolated so its direct pipeline
construction obeys the production live-instance contract.

## Verification

- `xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS'
  -only-testing:'Aagedal Photo Agent Tests/BrushRasterizationTests'`
  — **passed**, 16 tests in 1 suite, 0 failures. This built the app and test targets under Swift 6.
- `xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS'
  -only-testing:'Aagedal Photo Agent Tests/BrushCompositingTests'`
  — **passed**, 10 tests in 1 suite, 0 failures. This exercised the shared offscreen queue owner.
- `git diff --check -- 'Aagedal Photo Agent/Services/MetalEditPipeline.swift'
  'Aagedal Photo Agent Tests/IPTCMetadataTests.swift' docs/app-improvement-audit-plan.md
  docs/metal-edit-pipeline-executor-validation.md` — **passed**, no whitespace errors.

The test host emitted pre-existing environment noise (`MDB_MAP_FULL` from its persistence store and a
SwiftUI background-publication warning); neither command reported a test failure or build warning tied
to MetalEditPipeline.
