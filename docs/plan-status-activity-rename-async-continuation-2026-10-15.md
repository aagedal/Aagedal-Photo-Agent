# Activity resume and Batch Rename async continuation — 2026-10-15

This continuation follows the [metadata file-action continuation](plan-status-file-action-async-continuation-2026-10-15.md).
The broad audit remains 66 of 75; no release qualification gate is closed.

## Changes

Activity resume and Batch Rename preparation now await Caption/Metadata Review
durability instead of calling the synchronous compatibility bridge. Shared async
preparation holds editor/command admission until buffered capture and retained
queued writes complete. Missing editor handlers and save failures refuse the action;
cancellation finishes admitted writes and abandons the action. Workspace, folder and
selection replacement reject delayed actions. Rename also verifies the sheet request
identity and rechecks context after face/analysis writer quiescence.

Activity owns one resume task from retained-evidence validation through navigation.
Repeated requests are refused, and closing Activity cancels delayed navigation and
releases the selected workflow reservation. A successful handoff transfers ownership
to Deadline even if dismissal cancels the Activity task. Rename cancellation after
writer preparation or the Develop save reopens writers before acquiring the filesystem
execution reservation or moving files. Existing transaction, rollback, preservation
and reassociation behavior remains in the execution service.

The unused ContentView synchronous transition helper is removed. Synchronous
compatibility APIs used elsewhere remain; this does not establish elimination of all
MainActor filesystem work or application-wide performance warnings.

## Verification

Regression coverage exercises retained writes with delayed completion, command
exclusion, changed target context, missing handlers, editor failure/retry and
cancellation. Rename coverage checks original bytes and absent destination files
while metadata persistence waits, duplicate execution refusal, cancellation before
moves and reopening writers after quiescence. Activity coverage checks exact workflow
identity, repeated requests, declined navigation, cancellation during validation and
navigation, and successful ownership transfer during dismissal.

One subagent implemented Activity resume and reviewed the combined change. Review
identified the successful-handoff cancellation edge case, which is covered by a
regression. Native file-action interaction, actual local/network/iCloud/read-only-volume
latency, representative RAW/HDR memory, accessibility and distribution packaging
qualification remain open.

Repository validation passed using a writable temporary compiler cache:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-remaining-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-remaining-module-cache \
scripts/ci/validate_repository.sh
```

Console evidence: `/private/tmp/aagedal-remaining-barriers-repository.log`.
The initial default-cache invocation was sandbox-blocked. Xcode also required access
to existing development package/compiler caches. Ignored AuraFace and web runtime
resources were copied from the main checkout for verification; they are not source
changes. Compilation exposed and corrected an actor annotation on the Rename context
closure and a Swift Testing macro sendability error in an Activity test.

Focused test command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/CaptionSessionTests' \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameSheetStateTests' \
  -only-testing:'Aagedal Photo Agent Tests/DeliveryWorkflowActivityModelTests' test
```

The focused run passed **55 tests in three suites**, zero failures/skips, in
0.863 seconds of Swift Testing runtime. Result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_13-23-05-+0200.xcresult`.
Console evidence: `/private/tmp/aagedal-remaining-barriers-focused-final.log`.

The integrated run passed **4,145 total tests in 402 suites**: 4,143 passed,
zero failures, and the two existing opt-in Sony fixture skips. Swift Testing runtime
was 137.646 seconds. The xcresult summary reports no runtime warnings. Existing
`MDB_MAP_FULL` messages remain in the console; neither the focused nor integrated
console recorded Main Thread Checker or Thread Performance Checker messages. This
is not application-wide warning-remediation or performance qualification.

Integrated result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_13-25-51-+0200.xcresult`.
Console evidence: `/private/tmp/aagedal-remaining-barriers-integrated.log`.

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates test-without-building
```

`git diff --check` passed after the final documentation updates.
