# macOS core-workflow UI smoke validation

**Date:** 2026-08-25  
**Scope:** App improvement audit plan 2.2, small XCUITest smoke target

The shared `Aagedal Photo Agent UI Smoke Tests` scheme builds a dedicated macOS UI-testing
bundle and the app under test. `CoreWorkflowSmokeTests` creates a fresh temporary fixture root for
every test and covers:

- reliable launch followed by opening a two-photo folder;
- Import Overwrite preflight, including explicit confirmation copy and cancellation preserving the
  existing destination bytes;
- Caption headline editing and `Save & Next` advancing only after the sidecar-first save succeeds;
- Batch Rename opening a prepared two-file preview;
- Deadline creating an isolated default profile, running live preflight, and publishing phase,
  readiness, and next-action state; and
- an unavailable-folder failure that retains `Open Another Folder` and `Dismiss` recovery actions.

## Deterministic boundary

The app recognizes the seam only when launched with the explicit `--ui-testing` argument. Tests
pass disposable folder/source/destination/profile-store paths, bypassing nondeterministic system
file panels and saved user state while exercising the production Browser, Import, Caption, Batch
Rename, and Deadline views and models. UI-test launches also omit unrelated cloud, backup,
migration, trust-list, and network startup jobs. Interactive launches never contain this argument
and follow the unchanged startup path.

Stable accessibility identifiers were added at the Import workspace/start action and reusable
metadata text inputs. Existing Browser, Caption, Batch Rename, and Deadline workspace/readiness
identifiers are used directly.

## Commands and results

Project integration discovery passed and listed all three targets and shared schemes:

```sh
xcodebuild -list -project 'Aagedal Photo Agent.xcodeproj'
```

The final signed incremental test build passed with no diagnostic output:

```sh
xcodebuild build-for-testing -quiet \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AagedalPhotoAgent-UI-Smoke-DerivedData-2
```

The full execution command built successfully but this desktop host failed before any test body
started because macOS automation mode could not initialize:

```sh
xcodebuild test -quiet \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/AagedalPhotoAgent-UI-Smoke-DerivedData-2 \
  -resultBundlePath /tmp/AagedalPhotoAgent-UI-Smoke-2.xcresult
```

Result: `The test runner failed to initialize for UI testing` with underlying error
`Timed out while enabling automation mode` after 68.598 seconds. A
`test-without-building` retry restricted to `testLaunchAndOpenFolder` remained blocked waiting for
the local macOS worker/LaunchServices and was interrupted after 204.302 seconds. These are runner
initialization failures, not test assertion failures; execution still needs a UI-capable CI host or
a local session whose Xcode test runner can enter automation mode.

This completes the audit item to add the focused smoke target and coverage. It does not by itself
claim the broader exit gate that CI is already executing the suite or that the separate manual OS
assistive-technology matrix has passed.
