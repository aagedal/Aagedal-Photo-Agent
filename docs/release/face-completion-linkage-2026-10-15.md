# Exact face completion linkage — 2026-10-15

This continues the [native review worker](native-face-review-worker-2026-10-15.md)
on baseline `a808a61`, with the application/test changes in this working tree.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Changes

Native review previously selected a terminal receipt by operation ID and published
it without comparing the remaining fields to the original review. Receipt publication
now requires matching intent and operation IDs, inventory revision, photo count,
normalized scan/reset options, completed receipt phase, face-scan operation kind,
terminal operation state and the same completion outcome.

The retained review worker performs the read and comparison before returning a
receipt to the main actor. Cancellation and presentation-generation checks still
precede publication. Missing, incomplete or mismatched evidence leaves the terminal
operation visible, reports the inspection failure and preserves the durable archive.
It cannot repopulate consent, enable cancellation of finished work or replay the scan.
Receipt failures now have descriptive messages for native inspection.

This strengthens completion evidence within the current native session. It does not
implement durable helper request/epoch retention, authenticated face presentation,
request-to-operation admission linkage or descriptor-anchored physical scanner effects.
Those remain required before helper execution is exposed.

## Verification

Disposable generated photo bytes under `/private/tmp` exercise substituted intent
and operation IDs, revision, photo count, scan/reset options, incomplete phase,
conflicting outcome and absent receipt. Each case preserves the verified operation
and its original durable receipt, rejects publication and replay, and checks unchanged
fixture photo bytes. Additional checks reject a different workflow and nonterminal
operation. Existing successful, failed, cancelled/dismissed and blocked-read paths
remain covered by the focused suites.

Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0, build 742.
Verification uses existing development package caches and
`/private/tmp/aagedal-settings-search-build`. Ignored AuraFace
and web-runtime resources were copied from the main checkout, preserving symlinks;
they are not source changes. The initial sandboxed Xcode invocation could not write
compiler/package caches; the development-cache invocation was authorized.

Focused command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' test
```

The focused run passed **63 tests in four suites**, zero failures/skips, in
1.355 seconds of Swift Testing runtime. The nine substitution cases all pass.
The result summary reports zero runtime warnings. Console:
`/private/tmp/aagedal-face-linkage-focused.log`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_22-51-56-+0200.xcresult`.
Reading the result summary also required authorized Xcode report-cache access.

The first integrated run reports 4,163 total tests: 4,159 passed, two failures and
the two existing opt-in Sony skips. The failures are in unchanged transcription
binding (`expiredPlan`, `new-private-directory` parameter) and the 10,000-file
rename timing check. Its console records a 320.171-second ContinuousClock benchmark
while Swift Testing reports 4.179 seconds for that test; Xcode reports 1,954.599
seconds for a run whose Swift Testing runtime is 216.246 seconds. These discrepancies
suggest a host timing interruption; no definitive host-sleep cause is established.
Console: `/private/tmp/aagedal-face-linkage-integrated.log`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_23-02-37-+0200.xcresult`.

Both affected suites pass without source changes on rerun: **41 tests in two
suites**, zero failures/skips, 22.613 seconds of Swift Testing runtime. The rename
benchmark reports 6.730 seconds and 47.0 MiB resident growth. Console:
`/private/tmp/aagedal-face-linkage-timing-rerun.log`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_23-37-44-+0200.xcresult`.
Automatic permission review timed out before the first rerun could start; the
permitted retry was authorized and completed. Timing thresholds were not relaxed.

The final integrated rerun passed **4,163 total tests in 402 suites**: 4,161
passed, zero failures and the two existing opt-in Sony skips. Swift Testing runtime
was 166.385 seconds; the result summary reports zero runtime warnings.
The rename benchmark reports 8.055 seconds and 58.5 MiB
resident growth. Console: `/private/tmp/aagedal-face-linkage-integrated-final.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_23-40-40-+0200.xcresult`.
The integrated invocation uses the focused command's configuration and
`test-without-building` with no `-only-testing` arguments. Existing `MDB_MAP_FULL`
console observations remain; neither focused nor final integrated console recorded
Main Thread Checker or Thread Performance Checker messages. This does not establish
application-wide warning remediation or performance qualification.

Repository validation passed with temporary compiler caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-face-linkage-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-face-linkage-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-face-linkage-repository.log`.
Final `git diff --check` passed.
No new native interaction, real-volume latency, warning-remediation, distribution
qualification or independent agent review is claimed.
