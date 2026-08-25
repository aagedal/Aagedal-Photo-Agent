# Deadline capture revision validation — 2026-08-25

## Scope

Phase 3.3's Deadline capture follow-up only: give Deadline an owned typed revision model, ignore
unrelated preferences, and debounce expensive live-fact capture. Startup ordering, image/GPU memory,
investigation privacy, and delivery recovery were intentionally outside this change.

## Implementation evidence

- `DeadlineLiveCaptureRevision` is a `Hashable`, `Sendable` value owned by the Deadline live-snapshot
  boundary. Its named members cover the exact request input families: selected source facts,
  metadata, profile, rename/template resources, export/develop configuration, connection inventory,
  required lists, rename directory, and validation preferences. `ContentView` now uses this typed
  value as its SwiftUI task identity instead of XOR-folding broad application state into one number.
- `DeadlineValidationPreferenceSnapshot` contains only the effective metadata requirement levels and
  minimum lengths used to build Deadline's current validation profile. The app may still receive the
  process-wide `UserDefaults.didChangeNotification`, but `DeadlinePreflightLiveSnapshotModel` only
  publishes a changed capture identity when that typed snapshot changes.
- `DeadlinePreflightLiveSnapshotModel.refresh` waits for a cancellable 150 ms debounce before clearing
  the prior publication or starting detached filesystem/source-revision capture. SwiftUI replacement
  task cancellation therefore coalesces rapid relevant edits, while the existing coordinator keeps
  its cancellation and latest-publication gate for work that has already started.

## Characterization and verification

Command:

```sh
xcodebuild test \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightLiveSnapshotAdapterTests'
```

Result: **passed**, 13 Swift Testing tests, 0 failures, in 0.130 seconds on 2026-08-25.
The focused suite includes explicit characterization that:

1. changing `showOriginalThumbnails` does not advance Deadline's preference snapshot, while changing
   metadata validation requirements does;
2. cancelling a pending debounced refresh before its 100 ms test interval performs no capture, and
   the replacement request is the sole captured and published input; and
3. the existing replacement-cancellation/latest-wins and typed live-projection tests remain green.

The same run compiled and linked the production application target successfully before executing the
focused tests. Xcode emitted an existing App Intents "no dependency" warning and runtime persistence/
Metal diagnostics; none were compiler errors or test failures.
