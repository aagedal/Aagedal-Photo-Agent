# Native cancelled face-review capacity maintenance — 2026-10-16

This continues the [3.0 coordinator](coordinator.md) on baseline `77f0d35`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

Automation Settings can inspect bounded face review archive capacity without creating
absent storage, review the cancelled request paths and IDs, and explicitly confirm
removal. Cancel leaves the archive untouched. Cleanup atomically compares the original
epoch and complete cancelled record evidence. Newly cancelled or changed records require
another inspection. Only cancelled coordination records are retired; active and expired
awaiting-review records retain their exact original options, inventory and lifetime.
The submission epoch rotates in the same durable transaction, preventing replay of
retired handles. Clients must refresh capacity for subsequent new requests.

Inspection and cleanup run on a retained serial Dispatch actor. Cancellation before
mutation refuses; committed cleanup returns its durable outcome. Dismissal invalidates
presentation while retaining busy ownership until the worker drains. Stale, duplicate
and cancelled confirmations cannot submit cleanup. Corrupt or unsafe storage fails closed.
No helper cleanup tool, scanner consent, model initialization or execution route is added.
The existing read-only intent view retains its authorization-revision reset behavior.

One sub-agent implemented backend/model tests; another independently reviewed the slice.
Review identified a displaced authorization revision modifier in the Settings layout;
it was restored before verification. No remaining blocking review finding was reported.

## Verification

Source/test/project changes were uncommitted during verification. Disposable generated
photo/audio fixtures and private temporary archives are used, with no user photos or
production automation configuration. Ignored pinned AuraFace and web runtime resources
were copied from the main checkout; tracked resource files remain unchanged.

The initial restricted Xcode invocation could not write existing compiler/package caches.
The normal-access retry uses the existing development signing configuration and caches.
Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0/build 742.
Evidence directory: `build/face-review-maintenance/`.

Focused regression passes **16 tests in two suites**, zero failures/skips, in 0.317
seconds of Swift Testing runtime. It covers absent read-only storage, stale and raced
cleanup, full-record mismatch, replay refusal, active evidence preservation, pre-mutation
cancellation, exact confirmation and delayed worker dismissal/drain.

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/AutomationFaceReviewMaintenanceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanReviewRequestStoreTests' test
```

Focused console: `focused.log`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_19-35-46-+0200.xcresult`.
Integrated regression uses the same command without `-only-testing` arguments and passes
**4,199 total tests in 408 suites**: 4,197 passed, zero failures and the two existing
opt-in Sony fixture skips, in 146.829 seconds of Swift Testing runtime. Its result summary
reports zero runtime warnings. Neither console records Main Thread Checker or Thread
Performance Checker messages. Existing `MDB_MAP_FULL` observations remain; the 10,000-file
rename benchmark reports 4.250 seconds and 65.9 MiB resident growth. This does not establish
application-wide warning remediation or real-volume performance qualification.

Integrated console and summary: `integrated.log`, `integrated-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_19-42-02-+0200.xcresult`.

Repository validation passes with temporary compiler caches (`repository.log`):

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-maintenance-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-maintenance-module-cache \
scripts/ci/validate_repository.sh
```

Actual persistent-pipe helper probing passes all **41 tools** (`helper.json`); bundled
model validation passes (`model.json`). Signature verification during active integrated
resource copying saw an invalid seal; completed-app deep/strict development verification
passes (`signature-final.log`). Final repository validation passes (`repository-final.log`).

Signed native acceptance passes **one test**, zero failures/skips, in 34.778 seconds.
The existing installed-pair qualification now includes capacity inspection, Cancel with
byte-identical archive evidence, explicit removal, epoch rotation and exact surviving
active-record comparison. All other protected photo/audio/authorization/request artifacts
remain byte-identical; no face data or execution operation is created. Four actual bundled
helper calls retain wrong-epoch refusal and exact read-only inventory/options/expiry
presentation before maintenance. Normal Quit releases the real listener; the external
probe confirms fixture cleanup, unchanged host preferences and no execution submission.

```sh
python3 -B scripts/ci/probe_installed_native_review.py --face-review \
  --app 'build/face-review-maintenance/NativeDerivedData/Build/Products/Debug/Aagedal Photo Agent.app' \
  --derived-data-path build/face-review-maintenance/NativeDerivedData \
  --result-bundle build/face-review-maintenance/native.xcresult \
  --log build/face-review-maintenance/native.log \
  --output build/face-review-maintenance/native.json
```

The isolated build uses cloned local test/package caches and rebuilds its own development
artifacts. Exact native application executable SHA-256:
`a1793c3eb78e183c3b54285d921e885e362087aac11f75d27b5d5af35678bc77`; helper SHA-256:
`75efa0023d4112793d8c8558a219a9e3e698419571e52844f0097cdfe8add691`.
The exact native-tested artifact passes 41-tool helper probing, model bundle validation
and deep/strict development signature verification (`helper-final.json`, `model-final.json`,
`native-signature-final.log`). Final source/test/project hashes match
`source-sha256.json`; project plist lint and `git diff --check` pass. This qualifies
generated disposable fixtures and this native maintenance/presentation path, not scanner
execution, complete accessibility acceptance or distribution packaging.

## Remaining work

One-way durable face admission and exact reserved operation/owner linkage remain next.
A bounded investigation identifies these concrete requirements:

- Read existing request archives compatibly and persist one-way admission/linkage states
  with immutable admission ID, request ID/epoch, intent digest, reserved operation ID and
  owner ID. Refuse reused operation IDs and mismatched actual operation history.
- Match the registry's managed owner lease, face-scan kind, queued uncancelled state and
  exact reserved identity before recording linkage. Interrupted admission must remain
  inspectable without reopening consent or replaying work.
- Keep post-admission cancellation distinct from pre-admission cancellation. Capacity
  maintenance must never retire admitted or linked records as cancelled-only evidence.
- Add an explicit app-local intent adoption API preserving original wall expiry, boot
  witness and remaining continuous lifetime. Existing `prepare(arguments:)` recaptures a
  new window and must not be used to adopt durable requests.
- Reserve operation IDs before enqueue, link through coordinator lifecycle hooks, and
  carry durable cancellation and request/operation correlation into receipt validation.

These are next-slice design constraints, not implemented admission behavior.
Descriptor-anchored reset/thumbnail/document effects must precede helper execution. The initial read-only socket recapture can still outlast its I/O
waiter; this maintenance workflow does not alter that boundary. Native scanner/provider,
real-volume performance, accessibility and distribution qualification remain separate.
