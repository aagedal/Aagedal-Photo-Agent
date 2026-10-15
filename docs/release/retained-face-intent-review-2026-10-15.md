# Exact retained face-intent review — 2026-10-15

This continuation advances the helper-authenticated face review prerequisite in the
[ordered release work](readiness.md#ordered-next-actions). Baseline is
`2920409430095fdc6c8af3a458103c27dcadcc67`; verification used the application/test
source included in this change before committing it.
State remains IMPLEMENTING. The broad audit remains 66 of 75.

## Implementation

The native review service and presentation model can now prepare an exact retained
face-scan intent by ID. They preserve its original inventory revision, ordered photos,
normalized scan/reset options, identity and expiry. They do not recapture a replacement
intent from a path. Preparing a replacement review revokes prior consent. Model
readiness and installation validation, scan acknowledgement and full-reset
acknowledgement remain required; presenting an ID never supplies consent.

The bounded intent store now records a process-local monotonic start/deadline before
inventory capture. Capture time consumes the five-minute admission lifetime. Both
wall and monotonic clocks must remain within their original bounds for inspection
and retained admission. Reopening a review cannot extend that original deadline,
including when the wall clock is frozen. Expired entries are pruned by either clock
when preparing another intent, preserving bounded capacity. Once work has been
admitted, its retained capability continues using the existing authority and drain
rules rather than being interrupted by preview expiry.

This app-internal API is a prerequisite for authenticated helper presentation. The
helper transport does not expose it yet. Authentication, durable helper request
linkage and descriptor-anchored physical effects remain mandatory before production
helper execution. No new helper tool, native UI workflow or release gate is claimed.

## Verification

Disposable generated photo bytes under `/private/tmp` exercise exact retained
identity/options, fresh acknowledgements, review replacement, unknown IDs, changed
inventory/authorization/session, frozen-wall expiry before review/approval/submission,
capacity reclamation, and expiry/backwards monotonic time during capture. Existing
scanner integration and native model readiness/cancellation tests remain in scope.

Environment: macOS 27.0.1 (26A434), arm64; development app version 3.0.0, build 742.
Repository validation passes using writable temporary compiler caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-retained-face-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-retained-face-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-retained-face-repository-final.log`.
The initial restricted Xcode run could not write existing compiler/package caches;
the development-cache invocation was then authorized. Ignored AuraFace and web
runtime resources were copied from the main checkout for development verification;
they are not source changes.

The initial focused run and final-source rerun each pass **58 tests in four suites**,
zero failures/skips; the final Swift Testing runtime is 0.897 seconds. The rerun
ensures the final approval checks and scanner integration fixture are compiled.
Focused console: `/private/tmp/aagedal-retained-face-focused-final.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_19-54-36-+0200.xcresult`.

The integrated run passes **4,157 total tests in 402 suites**: 4,155 passed,
zero failures, two existing opt-in Sony skips, in 137.873 seconds of Swift Testing
runtime. Console: `/private/tmp/aagedal-retained-face-integrated.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.15_19-55-43-+0200.xcresult`.
Reading its summary also required authorized development-cache access.

Commands use the repository's bounded development configuration:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' test
```

The integrated invocation uses the same configuration with `test-without-building`
and no `-only-testing` arguments.

The actual bundled helper probe passes **36 tools**, malformed-input recovery,
exit zero and zero stderr. Model bundle validation and deep/strict development
signature verification pass; trust-store access was authorized for signature checks.
Evidence: `/private/tmp/aagedal-retained-face-helper.json`,
`/private/tmp/aagedal-retained-face-helper.log`,
`/private/tmp/aagedal-retained-face-model.log`, and
`/private/tmp/aagedal-retained-face-signature.log`.

Existing `MDB_MAP_FULL` console messages remain. Focused/integrated consoles record
no Main Thread Checker or Thread Performance Checker messages; this is not broad
performance qualification. No independent agent review is claimed.

The existing native face consent/receipt/relaunch workflow passes **one test**,
zero failures/skips, in **39.580 seconds**. It exercises the existing native folder
review route, explicit scan/reset acknowledgements, successful retained receipt,
face-data persistence and absence of restored consent after relaunch. The retained-ID
route is covered by service/model and real-scanner integration tests, rather than
claimed as an exposed native/helper UI workflow.

Native command uses the same build flags with scheme
`Aagedal Photo Agent UI Smoke Tests` and
`-only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testReviewedFaceScanRequiresConsentAndRetainsReceipt' test`.
Console: `/private/tmp/aagedal-retained-face-native.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent UI Smoke Tests-2026.10.15_19-58-31-+0200.xcresult`.
The native console retains a main-thread responsiveness warning during this test;
no root cause or application-wide warning remediation is claimed. Existing speech
API deprecation and skipped App Intents extraction warnings are also recorded.
`git diff --check` passes. No broader native, accessibility, actual-volume performance,
or distribution qualification is claimed.

## Next

Connect an authenticated app-owned helper request to the exact retained review with
session/epoch binding and durable operation linkage. Keep helper face execution
unavailable until rooted physical writes retain descriptor authority through their
actual effect boundaries. Develop native execution/embedded commit authority,
Whisper distribution and broader release qualification remain open.
