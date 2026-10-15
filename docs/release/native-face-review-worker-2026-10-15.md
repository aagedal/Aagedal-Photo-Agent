# Native face review worker — 2026-10-15

This continues the responsiveness work around the [retained face review](retained-face-intent-review-2026-10-15.md).
Verification uses the working-tree changes on baseline `38ae61a`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Changes

Native face review now uses a retained serial Dispatch actor for Core ML preflight,
complete inventory preparation, approval revalidation and terminal receipt reads.
The original task retains cancellation and task-local context across the boundary.
Cancellation is checked before and after blocking work; delayed preparation cannot
publish after cancellation or dismissal. Native model capability validation remains
lock-only and does not load an installation on the main actor.

Terminal receipt I/O no longer runs on the main actor. Dismissal during the read
remains immediate; the returned receipt must still match the current presentation
generation before publication. A receipt-read failure preserves the completed operation
and durable receipt, reports the inspection failure, and cannot reapprove or replay
the scan. While the completed receipt loads, the UI shows that state and disables
scan cancellation; an older cancellation response cannot overwrite terminal progress.
Execution, explicit scan/reset consent and existing authority checks remain
owned by the existing services.

This does not implement authenticated helper face presentation or physical execution.
The helper currently has read-only folder preparation, while retained native intents
are process-local. Cross-process session/epoch request retention, exact durable
operation linkage and descriptor-anchored effects remain required. The previous native
main-thread warning has not been reproduced or attributed; no root-cause fix or
application-wide warning remediation is claimed.

## Verification

The final-source focused run passed **62 tests in four suites**, zero failures/skips,
in 1.239 seconds of Swift Testing runtime. Coverage adds blocked worker cancellation
with task-local context, cancelled/dismissed model loading, dismissal/cancellation during
blocked receipt I/O, terminal cancellation refusal and failed receipt inspection after
durable completion. No independent agent review is claimed.

Focused console: `/private/tmp/aagedal-face-review-worker-focused-final-source.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_21-58-17-+0200.xcresult`.

The integrated run passed **4,162 total tests in 402 suites**: **4,160 passed**,
zero failures and the two existing opt-in Sony skips. Swift Testing runtime was
149.711 seconds. Its xcresult summary reports no runtime warnings. Existing
`MDB_MAP_FULL` console observations remain; neither final console recorded Main
Thread Checker or Thread Performance Checker messages. This is not broad
performance qualification or evidence that the previous native warning is fixed.

Integrated console: `/private/tmp/aagedal-face-review-worker-integrated.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_22-03-13-+0200.xcresult`.
The result-summary tool also required access to Xcode's report cache.
Final project plist lint and `git diff --check` passed.

Repository validation passed with temporary compiler caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-face-worker-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-face-worker-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-face-worker-repository-final.log`.
The initial restricted Xcode attempt could not write existing compiler/package caches;
the development-cache invocation was authorized. Ignored development model and web
runtime resources were copied from the main checkout; they are not source changes.
The first authorized build compiled the app, then stopped at its signing check because
its build graph predated model provisioning. The next build passed model verification but stopped because the disposable web
runtime copy had expanded symlinks. That copy was replaced with symlinks preserved;
its complete file set and every file hash now match the preparation manifest.
Test compilation then exposed a Swift diagnostic failure on the fixture's nested
optional closure mapping. Splitting that expression into explicitly typed values
removes the ambiguous expression; the focused rerun compiles final source.

Focused test command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' test
```

The integrated command uses the same flags with no `-only-testing` arguments
and `test-without-building`, against the binaries from the final-source focused run.

## Remaining work

Authenticated helper/native request handoff and linkage, descriptor-anchored scanner
writes, native interaction and actual-volume performance evidence, Develop execution,
Whisper lifecycle/distribution and broader release qualification remain open.
