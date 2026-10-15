# History restore and direct Browser async continuation — 2026-10-15

This continues the [Activity and Rename durability work](plan-status-activity-rename-async-continuation-2026-10-15.md).
The broad audit remains 66 of 75; no release qualification gate is closed.

## Changes

Metadata history restore now reserves command admission before scheduling its asynchronous
preparation. Buffered editor capture and retained Caption/Review writes finish before the
existing restore transaction is admitted. Selection, folder and editor load identity reject
obsolete requests. The selected history entry is retained by value and looked up again after
durability, so trimming or replacement cannot redirect an old index to another point. Capture
or save failure preserves the draft and reports the error. Panel dismissal cancels preparation;
already admitted writes and restore transactions retain their durable completion.

Direct Browser commands for deletion, moves, rename, duplication, edit reset and IPTC removal
use asynchronous retained-draft preparation. Repeated commands are refused while preparation
owns admission. Review text stays frozen during the wait; commands recheck folder, display
generation, selection and relevant rename/removal inputs before entering their existing action
bodies. Unmounted Review editors still drain retained writes. Existing filesystem transactions,
rollback and restore compare-and-swap checks remain in their execution services.

There are no remaining production calls to the synchronous Caption coordinator flush APIs.
Compatibility APIs remain for existing test/support use. This does not establish elimination
of all MainActor filesystem work or application-wide performance warnings.

## Verification

One sub-agent implemented the Browser slice and reviewed history preparation. Regression
coverage gates retained writes before deletion/restore, checks duplicate exclusion and frozen
Review text, rejects changed context and cancellation, exercises capture failure/retry, refuses
missing history points, and drains writes without mounted Review editors.

Repository validation passed with writable temporary compiler caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-continuation-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-continuation-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-history-browser-repository.log`.

The initial restricted Xcode invocation could not write existing package/compiler caches.
The normal development-signing build compiled the application changes, then stopped because
this new worktree lacked the ignored AuraFace development model. The reviewed model and web
runtime were copied from the main checkout for verification; they are not source changes.

Focused validation command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MetadataEditorReadServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FieldMutationCallerTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionSessionTests' \
  -only-testing:'Aagedal Photo Agent Tests/QuickListFileCreationServiceTests' test
```

The initial focused run passed 107 tests in three suites. The expanded focused run passed
**113 tests in four suites**, zero failures/skips, in 1.838 seconds of Swift Testing runtime.
Compilation exposed and corrected a Swift Testing macro sendability error around the new
task-admission assertion. The first integrated run completed 4,151 tests with one source-audit
failure: an existing Quick List assertion required its cancellation call to be the first line
in panel dismissal. That assertion now checks cancellation within the handler without requiring
exact statement order; the existing Quick List behavior is retained. Expanded focused bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_14-22-49-+0200.xcresult`.
Console: `/private/tmp/aagedal-history-browser-focused-expanded.log`.

The integrated run uses the same compiled source:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates test-without-building
```

The final integrated run passed **4,151 total tests in 402 suites**: 4,149 passed,
zero failures, and the two existing opt-in Sony fixture skips. Swift Testing runtime was
135.905 seconds. The xcresult summary reports no runtime warnings. Existing `MDB_MAP_FULL`
messages remain in the console; neither the expanded focused nor final integrated console
recorded Main Thread Checker or Thread Performance Checker messages. This is not
application-wide warning-remediation or performance qualification.

Integrated result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_14-23-43-+0200.xcresult`.
Console: `/private/tmp/aagedal-history-browser-integrated-final.log`.

`git diff --check` passed after the final documentation updates.

## Remaining work

Native file-action/history interaction, actual local/network/iCloud/read-only-volume latency,
representative RAW/HDR memory, accessibility and distribution packaging qualification remain
open. Automated correctness and synthetic suspension checks do not establish end-to-end
performance on those volumes.
