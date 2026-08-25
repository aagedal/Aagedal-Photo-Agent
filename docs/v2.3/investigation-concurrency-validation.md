# Investigation strict-concurrency and Thread Sanitizer validation — 2026-08-24

The investigation, named-version, comparison, and report coordination boundaries compile as Swift
6 code with main-actor default isolation. A fresh Debug test build with Thread Sanitizer enabled
completed without a Swift concurrency diagnostic. The compiler invocation in the retained build
evidence includes `-swift-version 6`, `-default-isolation=MainActor`, and `-sanitize=thread`.

The focused sanitizer run exercised 140 tests across the following six suites:

- Analysis case, including repository writes, changed-source handling, analyzer progress/cache/
  cancellation, rename quiescence, read-only fallback, map state, and annotation history;
- Develop version catalog, including actor-backed persistence, flush coordination, dependency
  snapshots, reassociation, and every promotion failure boundary;
- Analysis pixel views and the actor-backed derived-view cache, including detached-render
  cancellation and cost-bounded eviction;
- Comparison coordinator and render service, including cancellation-aware serialized RAW decode;
- Analysis report snapshot and PDF rendering, including immutable capture, source revalidation,
  pagination, map/solar evidence, and privacy-oriented export options.

All 140 tests passed with zero failures, skips, or expected failures. Thread Sanitizer emitted no
race report. The result bundle is
`/tmp/aagedal-v23-investigation-tsan/Logs/Test/Test-Aagedal Photo Agent Tests-2026.08.24_22-32-12-+0200.xcresult`
for this development session.

## Coordination review

- `AnalysisCaseRepository` and `DevelopVersionCatalogRepository` are actors, so complete
  load/validate/save and fallback-index mutations are serialized per repository instance.
- `AnalysisRunner` is main-actor isolated by the target default. Its child tasks inherit that
  isolation for observable state and use a generation token so cancelled or superseded work cannot
  publish into a newly configured case.
- `DevelopVersionFlushCoordinator` explicitly owns its handler and flush tasks on `MainActor`.
- `AnalysisDerivedViewCache` and `ComparisonDecodeGate` are actors. Detached pixel rendering has a
  sendable renderer boundary and forwards consumer cancellation before publication or cache insert.
- PDF rendering is explicitly `@MainActor` and consumes only the already immutable, sendable report
  snapshot; it does not retain the live case model.

No production race or strict-concurrency defect was found, so this gate required no product-code
change. The evidence is limited to the exercised arm64 macOS paths. It does not replace GPU-driver,
external-monitor, long-running interactive cancellation, or second-architecture validation, which
remain separate release gates.

## Command

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/aagedal-v23-investigation-tsan \
  -enableThreadSanitizer YES \
  -only-testing:'Aagedal Photo Agent Tests/AnalysisCaseTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopVersionCatalogTests' \
  -only-testing:'Aagedal Photo Agent Tests/AnalysisPixelViewRendererTests' \
  -only-testing:'Aagedal Photo Agent Tests/AnalysisDerivedViewCacheTests' \
  -only-testing:'Aagedal Photo Agent Tests/AnalysisReportSnapshotTests' \
  -only-testing:'Aagedal Photo Agent Tests/ComparisonCoordinatorTests'
```
