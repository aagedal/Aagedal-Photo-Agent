# Metadata file-action async continuation — 2026-10-15

This continuation advances the synchronous compatibility callers left by the
[metadata transition continuation](plan-status-metadata-transition-async-continuation-2026-10-14.md).
The broad audit remains 66 of 75; no release qualification gate is closed.

## Changes

Advanced Export, Render and Sign, Copy/Paste IPTC, Save As, RAW archive and folder
render/export now enter the shared asynchronous Caption/Metadata Review durability
barrier. Their synchronous action bodies begin only after buffered editor capture
and queued persistence complete. Existing reservation ownership prevents overlapping
commands and freezes editing while persistence suspends. Save failure retains the
editor and reports the error; cancellation preserves admitted writes and abandons
the action. Callers without a mounted editor still drain retained drafts.

The file-action wrapper captures folder and selection before waiting and checks both
before starting the action. The shared barrier also checks workspace identity.
Replacing the command's target context abandons the delayed action. Existing export,
archive, signing and IPTC validation and transaction behavior remain in their action
bodies, including re-reading current metadata after durability.

## Verification

Repository validation passed, including all five bundled component checks and model
discovery. The initial sandboxed attempts could not write compiler/package caches;
normal-cache reruns were used. Ignored AuraFace and web runtime resources were copied
from the main checkout for development verification; they are not source changes.
Console evidence: `/private/tmp/aagedal-file-operation-repository.log`.

The first Xcode build compiled the application changes, then failed its signing
script because its build graph was prepared before the ignored AuraFace resource
was provisioned. The focused rerun passed **87 tests in five suites**, zero failures/skips, in
1.087 seconds of Swift Testing runtime. It covers Caption session, Metadata Review,
export pipeline, Advanced Export and RAW archive behavior, including the existing
reservation, FIFO, failure/retry and cancellation regressions. No new tests or
independent-agent review are claimed.

Focused result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_00-09-55-+0200.xcresult`.
Console evidence: `/private/tmp/aagedal-file-operation-focused-final.log`.

The integrated run passed **4,135 total tests in 402 suites**, zero failures and
the two existing opt-in Sony fixture skips (4,133 passed), in 140.319 seconds of
Swift Testing runtime. Result bundle:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_00-14-42-+0200.xcresult`.
Console evidence: `/private/tmp/aagedal-file-operation-integrated.log`.
Existing `MDB_MAP_FULL` observations remain. No Thread Performance Checker or Main
Thread Checker message was recorded in this console log; this is not application-wide
performance or warning-remediation qualification.

The integrated run uses the same compiled source with the repository's bounded
configuration:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates test-without-building
```

## Remaining work

Activity resume and Batch Rename preparation retain synchronous compatibility
barriers. Native file-action interaction, actual local/network/iCloud/read-only-volume
latency, representative RAW/HDR memory, accessibility and distribution packaging
qualification remain open. This slice does not establish elimination of all
MainActor filesystem work or application-wide performance warnings.
