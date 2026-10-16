# Durable face lifecycle integration — 2026-10-16

This continues the [durable admission backend](durable-face-admission-backend-2026-10-16.md)
on baseline `87cacc9`. State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

The operation bridge now acquires the exact rooted folder capability before durable
admission. After retention it rechecks local intent freshness, native authority and the
retained inventory. Managed coordinator hooks receive the actual live owner lease used
for enqueue: the first persists one-way admission, and the second verifies durable linkage
before any execution task is launched. Failed admission, receipt persistence, enqueue or
linkage releases the folder without scheduling work. Interrupted durable evidence stays
single use and inspectable.

The native scheduler accepts that retained capability and captures its exact scanner task
synchronously on MainActor. It does not look up or recapture a review after admission has
consumed the original evidence. The compatibility intent-based scheduler delegates to the
same retained-capability overload. A coordinator completion hook releases ownership and
revokes native consent even when cancellation or a start refusal prevents entry into the
work closure. Actual submissions retain their folder until the exact task drains; cancellation
never frees a still-running task's reservation.

Retained work checks durable request/admission/operation/owner correlation independently
of review expiry. Durable request cancellation is forwarded to operation history at safe
boundaries and observed by the exact-task watcher. Failed correlation/history reads stop
the exact scanner task and preserve uncertain completion evidence. A final durable check
after task/watcher drain also records cancellation that raced the last watcher poll.
Native consent remains an independent requirement through read and effect boundaries.

Receipts optionally retain the original request ID/epoch/digest, admission, operation,
managed owner and history binding. Completion inspection requires exact durable linkage,
the original intent and the actual terminal operation from the reserved history directory.
Legacy receipts cannot satisfy durable intents. Strict archive validation rejects malformed,
unknown, null, mismatched and duplicate durable correlation while preserving legacy receipts.

One sub-agent implemented and reviewed coordinator lifecycle hooks; another implemented
receipt correlation. Parent integration owns retained scheduling and cancellation tests.
The review found a test assertion running inventory validation inside an intentionally
cancelled task; validation correctly observes cancellation, so the ownership assertion now
uses an uncancelled validation task and independently checks reservation contention.
Independent integration review also identified a late cancellation/history race; final
post-drain reconciliation closes it, and the final review reports no remaining blocker.

## Verification

Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0/build 742.
Evidence directory: `build/face-durable-lifecycle/`. Fixtures use disposable generated photo
bytes and private temporary request/receipt/history archives. No user photos or production
automation configuration are involved. Ignored pinned AuraFace and web runtime resources
were copied from the main checkout. The initial restricted Xcode invocation could not write
existing package/compiler caches; the normal-access retry uses development signing.
The first two normal-access builds found test-only compile errors: a missed scheduler
helper in each native review test suite and an unsupported nested `#require` expansion.
They were corrected before test execution. Initial logs remain in
`focused-initial-build-failure.log` and `focused-second-build-failure.log`.

Focused verification uses:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/AutomationOperationExecutionCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanReceiptInspectionTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanIntentAdoptionTests' test
```

The final focused run passes **101 tests in seven suites**, zero failures/skips, in
2.490 seconds of Swift Testing runtime. Console: `focused.log`; summary:
`focused-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_21-27-52-+0200.xcresult`.
The first executed focused run passed 98 tests and reported three new test assertion
failures: read-only inspection of absent history correctly refuses, while one-way
admission can create an empty history archive. Assertions were corrected to distinguish
absence from empty retained history. Production source was unchanged by those corrections.
Initial execution evidence remains in `focused-first-execution.log`.

Regressions cover actual-lease linkage before work, interrupted enqueue/linkage,
pre-work cancellation finalization, receipt refusal after one-way admission, exact task
reservation lifetime, durable cancellation at task completion, expiry after retention,
continued authority after admitted expiry, strict receipt correlation and legacy compatibility.

Integrated verification uses the same built app/test bundle and command configuration,
without `-only-testing` arguments, with `test-without-building`. It passes **4,226 total
tests in 409 suites**: 4,224 passed, zero failures and the two existing opt-in Sony
fixture skips. Swift Testing runtime was 286.709 seconds. Console: `integrated.log`;
summary: `integrated-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_21-30-18-+0200.xcresult`.
Both result summaries report zero runtime warnings. Neither focused nor integrated
console records Main Thread Checker or Thread Performance Checker messages. Existing
`MDB_MAP_FULL` console observations remain. The 10,000-file rename benchmark reports
4.430 seconds and 62.0 MiB resident growth. These results do not establish application-wide
warning remediation or real-volume performance qualification.

Actual persistent-pipe helper probing passes all **41 tools** (`helper.json`, `helper.log`).
Model bundle validation passes (`model.json`). Final completed-app deep/strict development
signature verification passes with normal certificate access (`signature.log`); initial
restricted certificate access reported `CSSMERR_TP_NOT_TRUSTED`, and an attempted check
during rebuilding saw resources changing before final signing. Final verification followed
completed rebuilding. Source/test hashes match `source-sha256.json`; built artifact hashes
are retained in `artifact-sha256.json`. No new native UI qualification was run.

Repository validation passes with temporary compiler caches:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-lifecycle-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-lifecycle-module-cache \
scripts/ci/validate_repository.sh
```

Console: `repository.log`. No new native UI acceptance is claimed for this backend slice.

## Remaining implementation and qualification

Authenticated helper presentation remains read-only. The native durable request presentation
still needs an explicit adoption/review/start flow and completion-context wiring. This change
makes the backend operation adapter capable of accepting an explicitly adopted, separately
consented intent; it exposes no new helper execution or automatic native consent.

Complete descriptor-anchored reset, thumbnail and document effects before exposing helper
execution. Native consent/provider interaction, real local/network/iCloud volume latency,
accessibility, Instruments and distribution qualification remain separate release gates.
