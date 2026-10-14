# Caption and web import async continuation — 2026-10-14

This continuation addresses remaining Phase 3.1 filesystem and durability boundaries.
The broad audit remains 66 of 75; real-volume, Instruments, native accessibility,
device and signed-release evidence remain separate.

## Changes

Caption's ordinary queued drafts await the existing JSON/XMP replay transaction
without a semaphore bridge. One admitted request owns the FIFO head across suspension;
failure retains that request and blocks dependent writes. State, retries and conflict
recovery remain serialized on the queue. Async durable barriers suspend their callers,
and cancellation of a waiter preserves admitted persistence before reporting cancellation.
Conflict discard waits for resumed unrelated work before reporting its next failure.
Synchronous compatibility barriers remain available for callers that require them.
Caption's existing session preparation guard freezes the editor, navigation column,
action bar, shortcut monitor and command delivery while those async transitions run.
Other transition callers, including Deadline preparation, retain their existing
synchronous barrier until their editor policies can be migrated together.

Web import preparation, provenance JSON writes, working-copy creation and hashing,
sidecar read-back and cleanup use a retained serial Dispatch actor. These operations
retain caller task context and sample cancellation between filesystem operations.
Cleanup completes before success or error propagation and deliberately runs even for
cancelled callers. A nonempty or unreadable Originals directory preserves the batch.
Originals remain separate from metadata-enriched working copies, and copy verification
still precedes any metadata mutation.

Two implementation sub-agents worked on independent slices; a third reviewed queue
ordering, recovery, cancellation and preservation. Review identified the need to retain
the scoped-discard completion contract and freeze the Caption editor during suspended
durable transitions. Both concerns are addressed in the final implementation.

## Verification

Regression coverage adds suspended FIFO ownership, failed-head retry/dependent-write
blocking and cancelled-waiter durability. The existing conflict-recovery cases retain
their completed-unrelated-write and next-failure contracts. The Caption source audit
covers async flushing and editor/shortcut/command transition guards. Web regressions
cover blocked-worker MainActor responsiveness and task-local retention, cancellation
during verification, mismatched copy hashes and provenance-write failure preservation.

`scripts/ci/validate_repository.sh` passed with all five provisioned bundled components
validated. Project plist lint and `git diff --check` passed. Reviewed ignored AuraFace
and web downloader resources were copied from the main checkout for the development
build; they are not source changes. The initial sandboxed repository command reached
the Swift discovery check but could not write the compiler cache; its normal-cache
rerun passed. The first focused Xcode build found two missing explicit captures in
nested Caption queue closures; these were corrected before the final runs.

The expanded focused run passed **66 tests in eight suites**, zero failures/skips,
in 0.876 seconds of Swift Testing runtime. It covers Caption session, conflict recovery,
Metadata Review retained persistence, Caption speed tools, application termination,
batch-description admission, web original preservation and the new filesystem executor.
Result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_13-24-35-+0200.xcresult`.
Existing `MDB_MAP_FULL` log observations remain; no Thread Performance Checker message
was recorded in this focused console log, which is not application-wide qualification.

The final integrated run uses the repository's bounded configuration:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates test
```

The final integrated run passed **4,126 total tests in 402 suites** in 132.354 seconds
of Swift Testing runtime, with zero failures and the two existing opt-in Sony fixture
skips. Result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.14_13-28-51-+0200.xcresult`.
Six Security main-thread performance diagnostics and existing `MDB_MAP_FULL` observations
remain in its console log. No application-wide warning-remediation claim is made.
The built development app passed bundled model inspection and deep/strict signature
verification using the normal macOS trust store; sandboxed signature verification
could not establish development certificate trust. This is not signed distribution
or notarization qualification.

Console evidence is retained at `/private/tmp/aagedal-continuation-focused-final.log`,
`/private/tmp/aagedal-continuation-integrated.log` and
`/private/tmp/aagedal-continuation-repository-final.log`.

## Remaining work

Synchronous compatibility durability callers can still block their calling thread.
This change does not establish that all MainActor filesystem work has been removed,
or that Thread Performance Checker warnings are eliminated across the application.
Native interaction qualification, real local/network/iCloud/read-only-volume latency,
representative RAW/HDR peak memory and Instruments traces remain open. Existing empty
web-download success behavior is unchanged; this continuation focuses on filesystem
execution and preserving partial recovery material.
