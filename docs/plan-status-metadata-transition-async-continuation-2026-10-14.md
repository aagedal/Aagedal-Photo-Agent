# Metadata transition async continuation — 2026-10-14

This continuation advances the remaining Phase 3.1 durability boundaries from the
Caption/web-import continuation. The broad audit remains 66 of 75; no release
qualification gate is closed.

## Changes

ContentView's shared workspace/action transition path awaits captured Caption and
Metadata Review drafts instead of draining persistence synchronously inside a Task.
A token-owned reservation is acquired before task scheduling, rejects overlapping
requests, and freezes the workspace and command delivery while the durable barrier
is suspended. Failure keeps the editor visible and releases admission. Cancellation
preserves admitted writes and abandons the requested action. Admission releases
immediately before the synchronous action, allowing its nested authorized calls.

Caption's local durable actions share the reservation with the parent workspace.
Caption editor, navigation, shortcut and command guards observe both local session
and shared transition state. Metadata Review disables rows and actions while saving;
final buffered AppKit text and capture callbacks remain available to the barrier.
Verified baseline loading continues during transitions so lazy rows are not left
without an editor after a failed save.

Deadline production preparation awaits the mounted editor when present, or drains
retained drafts when the editor has unmounted. It checks cancellation afterward and
retains existing post-save preflight/profile/source validity checks. Previously its
unconditional mounted-editor flush could fail with handlerUnavailable in Deadline.

One implementation sub-agent handled shared admission and editor guards. A separate
read-only reviewer checked ordering, cleanup and edit preservation. Review removed
a baseline-load guard that could skip a lazy row without retry, and kept Copy Previous's
commit marker before its additional async read so a replacement photo is not marked saved.

## Verification

Regression coverage exercises synchronous reservation before task admission, exclusion
while a barrier suspends, failed-save retry admission and cancellation without action
publication. Deadline production coverage runs all four mounted/unmounted editor and
cancelled/noncancelled combinations; retained writes finish before cancellation or
post-save stale-preflight refusal. Existing Caption source audits observe the combined
session/shared editor, shortcut and command guards.

The initial focused run passed **57 tests in four suites**, zero failures/skips, in
0.272 seconds of Swift Testing runtime. It covers Caption session, Caption speed tools,
Deadline preflight/production preparation and Metadata Review validation. Its bundle is
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_14-25-27-+0200.xcresult`.
The final integrated run rebuilt the late Caption action-ownership refinements and
passed **4,132 total tests in 402 suites**, zero failures and the two existing opt-in
Sony fixture skips (4,130 passed), in 153.706 seconds of Swift Testing runtime. Its
bundle is
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_14-33-21-+0200.xcresult`.
The run uses the repository's bounded configuration:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates test
```

Existing `MDB_MAP_FULL` observations remain in both test logs. No Thread Performance
Checker message was recorded in this integrated console log; this is not application-wide
performance or warning-remediation qualification. No native UI or distribution-signing
qualification is claimed.

`scripts/ci/validate_repository.sh`, project plist lint and `git diff --check` passed.
The initial sandboxed Xcode/repository attempts could not write normal compiler and
package caches; normal-cache reruns completed. Reviewed ignored AuraFace and web
downloader resources were copied from the main checkout for the build; these are not
source changes. Console evidence is `/private/tmp/aagedal-transition-focused.log`,
`/private/tmp/aagedal-transition-integrated.log` and
`/private/tmp/aagedal-transition-repository-final.log`.

## Remaining work

Synchronous ContentView file-operation, Activity resume and rename-preparation
compatibility callers remain. This slice does not establish elimination of all
MainActor file work or application-wide performance warnings. Actual local/network/
iCloud/read-only-volume measurements, native interaction/accessibility, representative
RAW/HDR memory profiles and release packaging qualification remain open.
