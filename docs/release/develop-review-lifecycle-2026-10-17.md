# Develop review lifecycle — 2026-10-17

Continues the ordered Develop native review work on clean baseline `8308ae6`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

An app-side native review model retains its exact preparation and retirement tasks.
Dismissal immediately removes visible review evidence and invalidates its generation.
A late successful preparation retires its original review on an uncancelled task;
replacement preparation remains refused until preparation and cleanup drain. Failed
cleanup retains the exact review or failed-preparation ID for an explicit retry. A
cleanup retry never restores visible evidence or execution authority. The model owns
no writer, Start action, helper tool or deserializable consent.

Develop admission now rechecks session, authorization, template, configuration,
carriers and decoder evidence after durable retention before returning a review.
Cancellation or drift during that suspension retires the original retained evidence.
Failed cancellation preserves cleanup-only ownership, blocking execution and reserving
capacity until retirement succeeds. Failed durable execution admission likewise
preserves cleanup authority without restoring Start.

Retirement checks the exact evidence digest. It changes only awaiting-review records
to cancelled, preserves consumed records and accepts already-cancelled records or
matching cleanup tombstones. This covers a committed journal replacement followed by
an error, including an uncertain retain or admission return. Missing or conflicting
storage never manufactures a review. The originally captured digest is available
before retention suspends. Independent review identified these uncertain-return cases
and the implementation includes explicit fault injection at those boundaries.
Writable unchanged journal transactions also flush the registry directory before
acknowledging success, completing any earlier failed post-replacement directory sync.
Read-only inspection still performs no durability flush.

## Verification

Environment: arm64 macOS 27.0.1, development app 3.0.0/build 742.
Fixtures are disposable generated
PNG photos, templates and private journals under `/private/tmp`. Tests cover real
capture/admission and sidecar execution plus gated native model preparation/cleanup,
post-retention cancellation and carrier/session drift, refused storage and exact retry,
committed-then-thrown persistence returns, and permanent replay refusal.

The initial restricted Xcode invocation could not write normal compiler/package caches.
Normal-access verification uses the development signing configuration and existing
package caches. Ignored AuraFace and web-runtime resources were copied from the main
checkout and are not source changes.

The final focused run passes **82 tests in four suites**, zero failures/skips,
in **5.698 seconds** of Swift Testing runtime. Its result summary reports zero runtime
warnings. Command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchCaptureServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchExecutionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchStorageTests' \
  -only-testing:'Aagedal Photo Agent Tests/AutomationOperationRegistryTests' test
```

Console: `/private/tmp/aagedal-develop-review-focused-durability.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_20-10-37-+0200.xcresult`.
Summary: `/private/tmp/aagedal-develop-review-focused-summary.json`.
An earlier build overlapped integration of fault-injection tests and compiled them
against an older service interface; its compile failure is not counted as qualification.
The subsequent 66-test Develop run passed before the final directory-sync correction;
the 82-test result above verifies that correction too.

The integrated run uses the same configuration without `-only-testing` arguments.
It passes **4,279 total tests in 410 suites**: **4,277 passed**, zero failures and
the two existing opt-in Sony fixture skips, in **145.605 seconds** of Swift Testing
runtime. The result summary reports zero runtime warnings. The 10,000-file rename
benchmark reports 3.959 seconds and 58.6 MiB resident growth. Existing `MDB_MAP_FULL`
console observations remain; automated correctness does not close performance gates.

Console: `/private/tmp/aagedal-develop-review-integrated.log`.
Result: `/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_20-11-50-+0200.xcresult`.
Summary: `/private/tmp/aagedal-develop-review-integrated-summary.json`.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-develop-review-module-cache`:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-develop-review-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-develop-review-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-develop-review-repository-final.log`.
The persistent-pipe helper probe passes all **41 tools**; bundled model validation
and deep/strict development-signature verification pass. Commands:

```sh
python3 -B scripts/ci/probe_mcp_helper.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output /private/tmp/aagedal-develop-review-helper.json
python3 -B scripts/ci/validate_model_bundle.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
codesign --verify --deep --strict \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
```

Evidence: `/private/tmp/aagedal-develop-review-helper.json`, matching `-helper.log`,
`-model.log` and `-signature.log`. The restricted signature check reported
`CSSMERR_TP_NOT_TRUSTED`; normal certificate access passed. Result-summary extraction
also required normal Xcode report-cache access. Project property-list lint and
`git diff --check` pass. Two independent agents contributed lifecycle tests and
review; final review found no remaining concrete blockers for this bounded slice.

## Remaining work

The model is an app-side lifecycle building block; production Settings capture/review
presentation, native consent/Start and managed operation integration remain unwired.
Embedded owned-effect stages, synchronous descriptor-rooted physical commit authority
and watermark dependency admission remain required before production execution is
exposed. Actual provider/device, real-volume performance, accessibility, Instruments
and distribution qualification remain separate gates. No whole release gate closes.
