# Startup work orchestration validation — 2026-08-26

This checkpoint implements the app-improvement audit Phase 3.3 substep to make startup jobs
dependency-ordered, cancellable, and lazy when they are not required for first paint. It does not
claim cold/warm launch budgets or close the section exit gate.

## Implemented boundary

`Aagedal_Photo_AgentApp.init()` now performs only startup signpost initialization. The main content's
first appearance ends the cold-launch interval and idempotently schedules `AppStartupWorkCoordinator`
for a later main-actor turn. UI smoke launches continue to skip unrelated migrations, cloud watchers,
network refreshes, and backup prompts.

The coordinator preserves the required dependency order:

1. migrate legacy keyword-list sources;
2. migrate the legacy Known People database;
3. start the keyword-list, Known People, Teams, and Watermark cloud watchers;
4. start portable preference sync and keyword-list backups;
5. opportunistically refresh the cached C2PA trust list.

Every boundary checks task cancellation before starting the next stage. App termination cancels the
retained task, and duplicate SwiftUI appearance callbacks cannot schedule the sequence twice. The CIE
chromaticity background is no longer precomputed at startup: `ScopeRenderService` already computes and
caches it when the Gamut scope first requests it, so it remains genuinely on-demand.

## Deterministic regression coverage

`AppStartupWorkCoordinatorTests` proves:

- duplicate first-paint callbacks execute the ordered sequence exactly once;
- cancellation during a stage prevents every later stage from starting;
- cancellation while idle or after completion is harmless and cannot restart completed work.

The existing `AppStartupSignpostStateMachineTests` continue to prove balanced cold-launch,
warm-activation, and first-folder intervals.

Validation commands:

```sh
xcodebuild build-for-testing \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-startup-work-20260826 \
  -clonedSourcePackagesDirPath /Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/SourcePackages \
  -disableAutomaticPackageResolution

xcodebuild test-without-building \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-startup-work-20260826 \
  -clonedSourcePackagesDirPath /Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/SourcePackages \
  -disableAutomaticPackageResolution \
  -only-testing:'Aagedal Photo Agent Tests/AppStartupWorkCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/AppStartupSignpostStateMachineTests'

git diff --check
```

Results:

- build-for-testing: **succeeded**;
- focused tests: **7 tests in 2 suites passed**;
- result bundle: `/tmp/aagedal-startup-work-20260826/Logs/Test/Test-Aagedal Photo Agent Tests-2026.08.26_22-32-46-+0200.xcresult`;
- whitespace validation: **passed**.

## Remaining manual evidence

Representative-device Instruments captures are still required for cold launch, warm activation, and
first-folder interaction. Explicit performance budgets must be agreed and met before Phase 3.3's exit
gate can close. The separate Phase 3.1 audit remains responsible for moving potentially blocking
filesystem operations behind asynchronous service boundaries; deferring migration until after first
paint does not claim that broader work.
