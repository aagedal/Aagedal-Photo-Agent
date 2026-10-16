# Durable face admission backend — 2026-10-16

This continues the [3.0 coordinator](coordinator.md) on baseline `75813b8`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

The face review archive reads existing version-one evidence and writes a strict
version-two archive on its next mutation. A one-way admission reserves an immutable
admission ID, original request ID/epoch/digest, operation ID, managed owner ID and
operation-history location. Admission holds history before request storage, rejects
existing operation history and duplicate retained reservation identities, checks the
original wall/boot-bound continuous lifetime, and commits before enqueue. A failed or
interrupted enqueue leaves an inspectable admission that cannot reopen review or retry
execution. These records are coordination evidence, not native consent.

Linkage holds the same lock order and verifies the actual reserved operation in the
reserved history directory with its live owner lease. Only a managed, queued,
uncancelled face operation belonging to the exact reserved owner can link. Both request
and operation cancellation refuse linkage. Expiry limits admission/linkage; a future
retained executor can check exact request/admission/operation/owner correlation and
durable cancellation after expiry. Post-admission cancellation preserves admission or
linkage and cannot enter cancelled-only capacity cleanup. No implicit eviction occurs.

An explicit app-session adoption API revalidates the original rooted inventory and
retains request ID/epoch/digest correlation. It preserves original wall dates and
clamps the local continuous deadline to the original wall and boot-witness remaining
lifetime. Repeated adoption reuses its session identity and never renews the deadline.
Expired adopted entries remain bounded session tombstones, including their inventory,
until the session store ends. Lookup and retention recheck exact durable evidence;
a final local clock check follows archive I/O. No consent is manufactured by adoption.

One sub-agent implemented adoption and independently reviewed the archive/registry
boundary. Parent review added the final local deadline guard and exact history-location
binding, with regression coverage.

## Verification

Disposable generated photo bytes and private temporary request/history archives are used; no user photos
or production automation configuration are involved. Ignored pinned AuraFace and web
runtime resources were copied from the main checkout; tracked resources are unchanged.
The initial restricted Xcode invocation could not write existing package/compiler caches;
the normal-access retry uses development signing and the existing local caches.
Evidence directory: `build/face-durable-admission/`. Environment: macOS 27.0.1
(26A434), arm64; development app 3.0.0/build 742.

The first focused run started while the admission data layout was still being edited.
It passed 42 tests but crashed two new tests during synthesized admission copying/equality.
The crashes retained invalid small pointers; an independent standalone structural
copy/cancellation reproduction passed. Both app and test intermediate objects were
removed before the clean retry, with source frozen for that build. Initial evidence is
retained in `focused.log` and `focused-initial-summary.json`, with result bundle
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_20-18-15-+0200.xcresult`.

The clean focused run passes **44 tests in four suites**, zero failures/skips, in
1.404 seconds of Swift Testing runtime. Both previous crash sites pass with unchanged
source after rebuilding app and test objects. The initial result is consistent with
mismatched compiled layouts, rather than a demonstrated cancellation-path defect.
Console: `focused-clean.log`; summary: `focused-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_20-27-43-+0200.xcresult`.

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanReviewRequestStoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanIntentAdoptionTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/AutomationNativeFaceScanReviewInvocationServiceTests' test
```

Integrated regression uses the same command without `-only-testing` arguments and
passes **4,214 total tests in 409 suites**: 4,212 passed, zero failures and the two
existing opt-in Sony fixture skips, in 139.822 seconds of Swift Testing runtime.
Both result summaries report zero runtime warnings. Neither clean focused nor integrated
console records Main Thread Checker or Thread Performance Checker messages. Existing
`MDB_MAP_FULL` observations remain. The 10,000-file rename benchmark reports 3.990 seconds
and 59.1 MiB resident growth. This does not establish broad warning remediation or
real-volume performance qualification.

Integrated console and summary: `integrated.log`, `integrated-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_20-33-53-+0200.xcresult`.

Repository validation passes with temporary compiler caches (`repository-final.log`):

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-admission-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-admission-module-cache \
scripts/ci/validate_repository.sh
```

Actual persistent-pipe helper probing passes all **41 tools** (`helper.json`), including
strict argument refusal and existing transport recovery. Model bundle validation passes
(`model.json`). Completed-app deep/strict development-signature verification passes
(`signature.log`). Exact artifact hashes are retained in `artifact-sha256.json`;
the bundled helper SHA-256 is
`169794d18cc620fe5a1f177626ab28523c8e458f1eda9f7902943ad503ddc50d`.
Source/test/project hashes match `source-sha256.json` after both passing test runs.
Project plist lint and final `git diff --check` pass. No new signed native UI qualification
was run for this backend-only slice.

## Remaining implementation and qualification

These backend APIs are not connected to the native consent/start action or the helper.
The current authenticated helper handoff remains read-only. The existing app-local
scanner route is unchanged. Next, retain the rooted folder capability before durable
admission, pass that exact capability through scanner scheduling, and use coordinator
lifecycle hooks to admit before enqueue and link before work. Adopted lookup intentionally
refuses once durable admission changes the original record; it must not be recaptured
through `prepare(arguments:)` or looked up as fresh review after admission.

`MCPFaceScanOperationService.submit` must retain before admission and release on every
pre-scheduling failure. Extend `AutomationOperationExecutionCoordinator.submit` with
managed hooks receiving its actual owner lease. The pre-enqueue hook persists admission;
the post-enqueue hook links before any worker is launched. Change the native scheduler
to accept the retained folder capability and synchronously capture its exact task,
without looking up the now-admitted review intent again. Preserve ownership through
refusal, cancellation and actual task drain.

Carry durable cancellation and original request/admission correlation through retained
work and receipt validation. Optional durable receipt correlation must include the
request ID/epoch/digest, admission, operation, owner and history binding; legacy receipts
cannot satisfy a durable request. Compare it with both admitted evidence and actual
terminal operation history. Test enqueue/link failures, expiry during retention,
withdrawal after scheduling, expiry after admission, mismatched receipts and release
only after the exact task drains. Complete descriptor-anchored reset, thumbnail and document
effects before exposing helper execution. Native scanner/provider, real-volume latency,
accessibility and distribution qualification remain separate gates. This backend-only
change makes no new native UI acceptance claim.
