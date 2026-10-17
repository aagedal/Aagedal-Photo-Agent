# Develop native review presentation — 2026-10-17

Continues the ordered Develop review work on clean baseline `f2d8b89`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

Automation Settings now discovers the authorized local Develop template library and
captures a new review from up to eight explicitly chosen photos. Discovery uses the
existing authorized inventory and routing rules, including refusal of unavailable or
iCloud template libraries; it does not create or fall back to another library.
Preparation fixes the policy to XMP sidecars and uses the production retained-source
decoder. It binds the original ordered photos, exact template revision, fixed policy
and production RAW profile/decoder preferences before capture, after capture and at
admission. Existing authority, carrier and post-retention validation remain mandatory.

The native view shows the template summary, crop policy, ordered paths and retained
source/XMP/app revision and decoder evidence. Capture creates only review evidence;
it changes no photo, XMP or app metadata. There is no consent or Start action and the
presentation service owns no writer or execution service.

A shared app-owned presentation retains its model and service when Settings closes.
Dismissal immediately withdraws the native session and clears visible review/selection.
The existing model drains late preparation and exact retirement. Failed cleanup remains
available on reopening, blocks template replacement and preparation, and permits only
an exact cleanup retry. Discovery results and open-panel callbacks reject obsolete
presentation generations. Authorization changes dismiss the review.

Synchronous capture and template discovery use a retained serial Dispatch actor.
Admission validation and journal transactions now each use retained Dispatch executors,
preserving task cancellation and task-local context across their actor boundaries.
The RAW configuration fingerprint shares the production preview's validated preference
reader, so malformed settings cannot silently choose another configuration.

Native worker testing exposed a stack overflow in the existing recursive capture builder:
each retained snapshot frame held large metadata/request temporaries. Capture now uses a
synchronous heap accumulator with non-inlined per-photo construction and final serialization.
The recursion returns only `Void`; all snapshot/reservation scopes remain nested through
terminal validation and unwind. Byte limits, baselines, decoder, watermark/conflict/orientation
refusals and post-snapshot authorization/carrier/template checks are preserved. Maximum-eight
native capture coverage exercises this boundary on the Dispatch executor.


## Verification

Environment: arm64 macOS 27.0.1 (26A434), development app 3.0.0/build 742.
Fixtures are disposable generated PNGs, templates and private admission journals under
`/private/tmp`. One agent added regressions and independently reviewed the integration
and capture refactor. No blocking review findings remain.

The final focused run passes **110 tests in five suites**, zero failures/skips,
in **5.469 seconds** of Swift Testing runtime. Its result summary reports zero runtime
warnings. Tests cover exact template discovery, ordered fixed-sidecar capture,
withdrawn session/stale template/configuration refusal, cancellation and retirement,
failed cleanup across Settings reopening, stale/excessive photo selections,
Dispatch/task-local context and the maximum eight-photo batch with unchanged source bytes.
The existing admission/storage/execution and template-discovery regressions also pass.
Command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath /private/tmp/aagedal-develop-native-verified.xcresult \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchCaptureServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchExecutionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchStorageTests' \
  -only-testing:'Aagedal Photo Agent Tests/AutomationOperationRegistryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPTemplateDiscoveryTests' test
```

Console: `/private/tmp/aagedal-develop-native-verified.log`.
Result: `/private/tmp/aagedal-develop-native-verified.xcresult`.
Summary: `/private/tmp/aagedal-develop-native-focused-summary.json`.

Earlier qualification attempts are retained: the initial restricted build could not
write compiler/package caches; normal-access verification uses existing caches and
development signing. A build overlapping interface/test integration compiled tests
against an earlier presentation interface. The subsequent run exposed three worker
stack overflows (`aagedal-develop-native-focused-final.log`/`.xcresult`). After the
accumulator fix, all tests ran without a crash; four new expectations compared
`/private/tmp` fixture spellings with the facade's canonical `/tmp` spelling. Those
expectations now obtain the canonical target from the facade, matching existing tests;
ordered selection and byte/sidecar preservation checks remain. The final focused run
above verifies both corrections. Ignored pinned AuraFace and web-runtime resources
were copied from the main checkout and are not source changes.

The integrated run uses the same configuration without `-only-testing`, with result
bundle `/private/tmp/aagedal-develop-native-integrated.xcresult`. It passes **4,284 total
tests in 410 suites**: **4,282 passed**, zero failures and the two existing opt-in Sony
fixture skips, in **135.221 seconds** of Swift Testing runtime. The summary reports zero
runtime warnings. Neither final focused nor integrated console records Main Thread
Checker or Thread Performance Checker messages. The 10,000-file rename benchmark
reports 3.619 seconds and 59.8 MiB resident growth. Existing `MDB_MAP_FULL` console
observations remain; these checks do not close performance qualification.

Console: `/private/tmp/aagedal-develop-native-integrated.log`.
Summary: `/private/tmp/aagedal-develop-native-integrated-summary.json`.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-develop-native-module-cache`:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-develop-native-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-develop-native-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-develop-native-repository-final.log`.
The persistent-pipe helper probe passes all **41 tools**; bundled model validation and
final deep/strict development-signature verification pass:

```sh
python3 -B scripts/ci/probe_mcp_helper.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output /private/tmp/aagedal-develop-native-helper-final.json
python3 -B scripts/ci/validate_model_bundle.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
codesign --verify --deep --strict \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
```

Artifact evidence: `/private/tmp/aagedal-develop-native-helper-final.json` and matching
`-helper-final.log`, `-model-final.log`, `-signature-final.log`. Earlier signature probes
ran before signing or during a subsequent build and reported unsigned/invalid resources;
the final check above runs after all Xcode activity completes and passes with normal
certificate access. Xcode result-summary extraction also required normal report-cache
access. Project property-list lint and staged `git diff --check` pass.

## Remaining work

Native consent, managed operation linkage/Start and physical execution remain unwired.
Embedded owned-effect stages, synchronous descriptor-rooted physical commit authority
and watermark dependency admission remain prerequisites for production execution.
Native end-to-end interaction, actual provider/device, real-volume performance,
accessibility, Instruments and distribution qualification remain separate gates.
No release gate or audit checklist count closes from this review-only boundary.
