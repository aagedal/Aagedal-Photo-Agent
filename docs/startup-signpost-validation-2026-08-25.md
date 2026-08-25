# Startup signpost validation — 2026-08-25

This checkpoint implements the instrumentation-only substep in app-improvement audit section 3.3.
It does not defer startup work, claim launch-performance budgets, or close the section exit gate.

## Capture boundaries

All intervals use `OSSignposter` with subsystem `com.aagedal.photo-agent` and category
`AppStartup`, so they appear under Points of Interest in Instruments:

- `ColdLaunch` begins at the top of `Aagedal_Photo_AgentApp.init()` and ends when the main
  `ContentView` first appears. This measures app-owned initialization through first SwiftUI content
  appearance; it deliberately does not claim pre-main/dyld time.
- `WarmLaunch` begins in `applicationWillBecomeActive` and ends in
  `applicationDidBecomeActive`. The transition model suppresses the initial activation during the
  still-open cold-launch interval, then records every later inactive-to-active cycle.
- `FirstFolderInteraction` begins on the process's first `BrowserViewModel.loadFolder` request and
  ends after phase-one scanning publishes and rebuilds the grid, or at the corresponding failure.
  This is the concrete first meaningful interaction used by the section's first-folder metric.

The interval names and result labels are static. No folder path, filename, identifier, metadata, or
other user content is logged. The successful first-folder result carries only a private aggregate
item count, and the repository's fail-closed unified-log privacy validator accepts the source.

## Deterministic regression coverage

`AppStartupSignpostStateMachineTests` exercises four transition contracts independently of the
unified log: cold-launch idempotence and balance, suppression of initial activation plus repeated
balanced warm activations, one aggregate-only successful first-folder result, and balanced terminal
failure. The pure state machine prevents duplicate SwiftUI/AppKit callbacks from opening or closing
an interval twice.

Focused verification command:

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aagedal-startup-signposts-20260825 \
  -only-testing:'Aagedal Photo Agent Tests/AppStartupSignpostStateMachineTests'
```

Result: build succeeded and all **4 tests in 1 suite passed**. Result bundle:

`/private/tmp/aagedal-startup-signposts-20260825/Logs/Test/Test-Aagedal Photo Agent Tests-2026.08.25_21-04-45-+0200.xcresult`

Additional checks passed:

```sh
bash scripts/ci/validate_repository.sh
python3 -B scripts/ci/test_logger_privacy_validator.py
python3 -B scripts/ci/validate_logger_privacy.py
plutil -lint 'Aagedal Photo Agent.xcodeproj/project.pbxproj'
git diff --check
```

The privacy validator covered 338 app Swift files and found only the 11 existing approved
non-identifying public interpolations. Manual representative-device Instruments captures and
explicit cold/warm/first-folder budgets remain required before section 3.3's exit gate can close.
