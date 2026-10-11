# Rooted face preparation and signed Whisper Settings — 2026-10-12

Baseline: `6c74001`, initially clean. This development continuation does not replace
published Beta 3 or close a whole release gate. State remains **IMPLEMENTING**.
Implementation commits: `a6b7be3` (face preparation/exact completion) and `4dc59c5`
(signed Whisper Settings controller integration).

## Behavior

The bundled MCP helper exposes read-only `prepare_face_scan` for one explicitly
authorized folder. Complete immediate local photo inventory is inspected twice under
an exclusive shared folder reservation. Enabled authorization, root/folder identities,
normalized full/jersey options and each image's filesystem witnesses bind the returned
snapshot revision. Empty, linked/hardlinked, pending-cloud and changed inventories
refuse; unsupported, hidden and nested files are outside the immediate image set.
Preparation checks no model readiness, creates no retained plan, grants no mutation
consent and schedules no scan or durable operation. The reservation ends on return.
Identity/timestamp evidence is not a content hash or an atomic external-edit snapshot.

Native scheduling now offers an exact submission handle that retains its task's typed
completion after the scanner clears its active slot. Subsequent scans or refusals
cannot replace that completion. It adds no helper permission or cancellation grant.

The existing Managed Whisper Settings controller can receive an explicitly supplied
signed catalog/distribution. Each bounded unique catalog entry is authenticated using
an application-supplied trust anchor. Selection stays inside that catalog; actions
retain inspected generations, install/update exact signed releases, restore missing
current weights, and remove weights without resetting replay protection. Generation-bound
read-only publication settlement preserves installed presence when cancellation races
publication, while the controller refuses provider admission until a fresh refresh.
Shipping Settings continues to use compiled model pins: production signing-key/catalog
provisioning and shipping wiring remain unfinished. Test-injected signed integration is
not production distribution evidence.

## Verification

Evidence is retained under ignored `build/continuation-9/`. Host: arm64, macOS
27.0.1 (26A434), Xcode 27.0 (27A266a). The existing reviewed ignored AuraFace package
and cached source dependencies were copied into this worktree for validation.
Disposable generated files and signed synthetic model/executable fixtures were used;
no user photo or production model/server authority changed.

Tests exercised the exact Swift source/test bytes now committed in `a6b7be3` and
`4dc59c5`; all 11 hashes match `source-sha256.json`. Only documentation was dirty
after those commits. Debug app: `build/continuation-9/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 742, development signed. This is a local development build,
not a newly published beta or a final Release candidate.

- Focused verification: **201 tests / six Swift suites**, zero failures/skips,
  3.006 seconds (`focused-verified.xcresult`, `focused-summary.json`,
  `focused-verified.log`). Includes exact task retention, complete rooted inventory,
  option/argument refusal, authority/inventory drift, release generations, invalid
  signatures/duplicate catalog models and signed publication-cancellation behavior.
- Integrated regression: **3,965 passed, two opt-in Sony skips, zero failures** out of
  3,967 tests / 392 Swift suites, 122.471 seconds (`full.xcresult`,
  `full-summary.json`, `full.log`). Four Caption/metadata-read QoS warnings in the
  result summary retain performance qualification. Test-host `MDB_MAP_FULL` logging
  also remains an observation.
- Native workflows: **two passed**, zero failures/skips (`native-face.xcresult`,
  `native-face-summary.json`, `native-face.log`). Complete-folder scanning of two
  generated JPEGs persists completion and byte-identical face data across relaunch
  (23.613 seconds); explicit jersey-rescan cancellation creates no face-data directory
  (12.750 seconds). The fixtures use an empty disposable Known People root and process-only
  browse-bar preferences. These qualify zero-face scan/persistence/cancellation behavior,
  not recognition accuracy or signed Whisper native UI. Desktop inventory before and after
  testing confirms no unrelated Photo Agent instance and no test app left running.
  Two native main-thread warnings retain performance qualification.
- Repository validation and whitespace checks pass (`repository-final.log`).
  Bundled-model verification and development signature verification pass after native
  testing (`model-bundle-final.log`, `signature-post-native.log`).
- Actual embedded persistent STDIO helper: **36 tools**, valid discovery, strict malformed/
  execution-argument refusals, zero stderr (`mcp-helper-final.json`). It advertises
  `prepare_face_scan`; `start_face_scan` remains absent.
- Independent architecture, source and final integration review passes. No whole
  feature/executor or release acceptance criterion is checked solely from these foundations.

Initial sandboxed attempts could not use external package/compiler caches. Copying the
existing dependency cache locally and approved Xcode cache access completed validation.
Early integration builds caught a response type and test isolation mismatch; both were fixed.
The first executed focused run found `/tmp` versus `/private/tmp` URL spelling in the exact
inventory assertion. Standardizing both exact ordered URL sets fixed it without removing
expected images or loosening inventory checks. Initial signature attempts preceded signing
or lacked system trust access; final approved post-native verification passes.

Commands (all Xcode runs share this derived-data directory):

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-9 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-9/full.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-9/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

Focused testing adds selectors `ActivityHistoryTests`, `MCPFaceScanAdmissionServiceTests`,
`MCPServerCoreTests`, `ManagedWhisperSetupModelTests`, `WhisperModelDistributionTrustTests`
and `WhisperModelDistributionStateStoreTests` and uses `focused-verified.xcresult`.
Native testing switches to scheme `Aagedal Photo Agent UI Smoke Tests`, selects
`CoreWorkflowSmokeTests/testCompleteFolderFaceScanPersistsAcrossRelaunch` and
`CoreWorkflowSmokeTests/testExplicitJerseyScanCancellation`, and uses `native-face.xcresult`.

## Remaining work

`start_face_scan` still needs authenticated native intent, rooted authority retained
through every asynchronous mutation, durable operation admission/progress and exact
cooperative cancellation. Postprocessing writes also need authority coverage. Thumbnail
persistence failures currently log separately from the final face-document completion;
resolve or explicitly bound that evidence before claiming an automation operation verified.
Production Develop-template writes/recovery, signed Whisper provisioning/shipping/native
acceptance, authentic media/cloud/device tests, accessibility, performance and other
external release gates remain open.
