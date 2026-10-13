# Native face review and replay-safe Develop cleanup — 2026-10-13

Baseline: `d0ac68d`, initially clean. Implementation: `d5b4c56`; regression corrections: `ff9ee05`. Two implementation agents and an independent
reviewer continued the 3.0 work. State remains **IMPLEMENTING**; no whole release
gate closes. Verification results below are completed separately from implementation.

## Implemented behavior

The browser face-scan context menu now offers **Review Authorized Face Scan…** using
that browser's existing scanner and a folder frozen when the review opens. Preparation
checks the authorized complete immediate inventory on a background executor and loads
the concrete CoreML installation before showing consent. A process-only model capability
binds the embedder instance and installation generation; every model publication rotates
that generation, including reinstalling the same version/path. Failed model loading is
unavailable, and expensive CoreML loading uses a separate serialization lock so readiness
and withdrawal do not wait for disk I/O.

The native review presents ordered photo names, exact incremental/full/jersey options,
saved-data effects and expiry. Scan consent is mandatory; full/jersey scans additionally
require explicit reset consent. Changing options invalidates the displayed review.
Approval is consumed atomically before admission I/O, and filesystem checks run outside
the capability lock with authority checks on both sides. Dismissal withdraws further effect
permission; actual retained work drains before ownership ends. The view shows scanner
counts, exact-operation cancellation and durable terminal receipts. Existing face groups
use the same scanner, avoiding a second disconnected cache. UI tests refuse personal
operation/authorization storage without explicit disposable native configuration.

Develop capture cleanup now has a read-only exact preview and a confirmed anchored
transaction. Only cancelled records retire; their IDs and evidence digests become compact
permanent tombstones. Awaiting and consumed records, photos and physical checkpoints remain.
The confirmation lists each exact ID, template and ordered photo path. Changed cancelled
sets or tombstone counts require a new review. Cancellation is checked before opening
storage and immediately before retirement. Missing read-only storage is never created.

Admission archive v1 remains readable without migration. Mutation writes strict v2 with
up to 128 full journals and 4,096 permanent tombstones within the existing 64 MiB bound.
Tombstones are never evicted; saturation refuses cleanup unchanged. Unknown/corrupt/unsafe
archives refuse unchanged. Retired identity reuse, changed evidence and old process/relaunch
review tokens cannot replay. Older binaries refuse the v2 archive after migration.

## Review

Independent review identified undisplayed cleanup records, queued cancellation and model
readiness based only on a URL. These are corrected with a locked preview projection,
preeffect cancellation checks and concrete model loading/installation authority. Final
review of cleanup, consent, lock responsiveness, options, live progress and test isolation
passes. No helper face execution endpoint is enabled. Physical face scanner writes still
use paths; descriptor-anchored publication remains required before helper execution.

Develop native execution, embedded owned-effect stages, synchronous rooted commit and
watermark authority remain open. Signed Whisper provisioning and broader hardware,
interoperability, privacy/legal, accessibility, performance and signed release gates remain.

## Verification

Evidence is retained under ignored `build/continuation-16/`. Generated disposable photos,
synthetic face workers, real bundled CoreML loading and private journals exercise these
contracts; recognition quality is not claimed. The pinned ignored AuraFace source package
was copied from the main checkout; the prepared locked downloader runtime was copied from
`/private/tmp/photo-agent-locked-runtime`. No neighboring source checkout was modified.

The first restricted Xcode attempt failed package resolution because compiler/package
caches were not writable. Approved cache access allowed compilation. The next run found
a Swift async-context semaphore test compilation error; the corrected test wraps the
synchronous gate wait, retaining deterministic withdrawal coverage. These failed runs are
retained as `focused.log` and `focused-v2.log`; they are not passing verification evidence.

The first executable focused run (`focused-v3`) reached 99 tests in seven suites and
failed one dismissal assertion: withdrawal correctly returned the review service's
`unavailableApproval`, while the test expected a presentation-model error. The corrected
assertion checks that exact refusal. This run is retained without claiming it passed.

Focused final implementation verification (`focused-v4.xcresult`) passes **99 tests /
seven suites**, zero failures/skips, in **4.883 seconds**. This includes real bundled
CoreML model-generation invalidation and failed-loading refusal.

The first full run (`full.xcresult`) executes **4,100 tests / 401 Swift suites** in
**129.957 seconds** and fails one unchanged baseline source assertion in
`CaptionWorkspaceSpeedToolsTests`: it expected `case .metadata: selection = .metadata`,
while the earlier Settings-search implementation uses `showDestination(.metadata)`
to clear the filter. The corrected guard checks that route and search clearing. No
application source changes accompany this test correction; the failed full run remains
retained. Final full regression (`full-v2.xcresult`, `full-summary.json`) passes **4,098 tests,
two opt-in Sony skips, zero failures**, out of **4,100 tests / 401 Swift suites**, in
**128.806 seconds**. Tested application source is `d5b4c56`; the full-run test source
includes the described
Settings assertion correction. Native test source additionally corrects its canonical
directory identity fixture from the ambiguous `Darwin.stat` spelling to `Darwin.lstat`.
The initial native compilation failure is retained as `native.log`; no application
source changes accompany either test correction. The final repository gate passes
(`repository-final.log`).
Four existing runtime QoS warnings in Caption-session and Metadata-editor tests and
test-host `MDB_MAP_FULL` logging retain the performance/environment gates.

The native runner (`native-v2.xcresult`) compiles both new workflows but fails both
before interaction with the exact error:

> Failed to activate application 'aagedal.Aagedal-Photo-Agent at /private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app' (current state: Running Background)

The capture workflow fails in **63.401 seconds** and face workflow in **62.054 seconds**.
No native cleanup commit/relaunch or face-consent execution acceptance is claimed.
`native-summary.json` and `native-v2.log` retain the failures. The app process was
running during activation; no matching crash report was observed. This is an unresolved
activation failure, not a proven product-root-cause diagnosis.

Computer-use fallback selects the exact build by absolute path. Initialization takes
**336.318 seconds**, then reaches its empty browser. Settings → Automation → Choose
Develop Capture Folder selects only `cua-fixture/Admissions`, containing three synthetic
historical states. The visible consumed explanation, exact one-cancelled-record preview
(ID/template/ordered path), confirmation layout, **Cancel** and **Refresh** are verified.
All three records remain visible; before/after image, journal and lock hashes match exactly
(`cua-fixture/before-sha256.json`, `after-sha256.json`, `observed-ui.json`). The screenshot
is available in the computer-use session; no screenshot file is claimed. Cleanup retirement,
relaunch and face execution are not exercised by this bounded fallback. Automation stays
off with no authorized roots; no personal record is removed or photo is opened. Settings
selection returns to General, the empty development app quits normally, and a process
check confirms no matching app/test runner remains. Native acceptance gates remain open.

All **15** final source/test/project hashes match `ff9ee05` (`source-sha256.json`); application
source is unchanged from `d5b4c56`. Final deep development-signature verification passes
again after native compilation (`signature-final.log`). The actual helper and model
bundle checks also pass again on that build (`helper-final.json`, `helper-final.log`,
`model-bundle-final.log`).

Repository validation passes (`repository.log`). The actual persistent STDIO helper
passes **36 tools**, strict malformed argument handling, exit zero and zero stderr
(`helper.json`, `helper.log`). Bundled model verification and strict deep development
signature checks pass (`model-bundle.log`, `signature.log`); this is not notarization.

Environment: arm64 MacBook Pro, macOS **27.0.1 (26A434)**, Xcode **27.0 (27A266a)**.
Tested Debug app: `/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app`,
version **3.0.0**, build **742**. This is a development continuation, not a release candidate.

Verification commands:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchCaptureServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchStorageTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FaceEmbeddingTests' \
  -only-testing:'Aagedal Photo Agent Tests/SettingsSearchTests' \
  -resultBundlePath build/continuation-16/focused-v4.xcresult test
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-16/full-v2.xcresult test
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent UI Smoke Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testReviewedFaceScanRequiresConsentAndRetainsReceipt' \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testDevelopCaptureInspectionPreservesHistoryAndPhotos' \
  -resultBundlePath build/continuation-16/native-v2.xcresult test
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-16/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```
