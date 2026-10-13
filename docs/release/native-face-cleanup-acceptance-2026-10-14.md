# Native face consent and Develop cleanup acceptance — 2026-10-14

Baseline: `09301a7`, initially clean. Application source is unchanged. This continuation
corrects and expands `CoreWorkflowSmokeTests`; no production helper executor is enabled.
State remains **IMPLEMENTING**. The previously blocked native face-consent and cancelled
Develop capture cleanup/relaunch cases now pass; no whole release gate closes.

## Observed behavior

The native browser's **Review Authorized Face Scan…** workflow prepares two generated
JPEGs using the bundled CoreML installation. Start remains disabled without scan consent.
Changing to Full Scan invalidates the earlier review. After preparing again, scan consent
alone still permits neither execution nor creation of face data/receipts; explicit reset
consent is required. The resulting receipt records exactly two photos, full scan, no jersey
recognition, completed/verified outcome and zero failed photos. The browser shows completed
scan state. Relaunch preserves face-data and receipt bytes. Opening another review offers
preparation only: historical completion does not reconstruct native consent or a Start action.
These generated images qualify consent and persistence, not recognition accuracy.

Automation Settings inspection leaves absent admission storage absent and preserves a
corrupt archive unchanged. A synthetic consumed capture exposes its historical explanation
and ordered evidence without changing the journal or photo. Cancel on the exact cancelled
capture cleanup preview leaves the archive unchanged. Confirmation retires exactly one
cancelled capture, retains one consumed journal and one permanent tombstone, and preserves
the photo bytes. Relaunch presents the consumed capture collapsed and preserves the retired
archive and photo bytes. Replay refusal itself remains covered by the existing storage tests;
this UI case does not attempt to execute a retired capture.

All photos, Known People data, authorization, operations, admission journals and receipts
use disposable UI-test locations. Teardown terminates the test app and removes the fixture
root. No personal capture or photo is deleted.

## Test corrections and verification

Evidence is retained under ignored `build/continuation-17/`.

- Restricted initial Xcode execution fails compiler/package cache access (`native.log`).
  The retry with approved cache access builds and activates the app successfully. The
  earlier Running Background activation failure is not reproduced; no root-cause claim
  or application activation workaround is made.
- `native-v2.xcresult`: face consent passes in 31.128 seconds. Develop inspection stops
  at an XCTest query exception: the 171-character explanation exceeds the 128-character
  string-identifier limit. This is failed evidence, not cleanup acceptance.
- `native-v3.xcresult`: extended face consent/relaunch passes in 42.944 seconds. The
  label-only explanation predicate fails; exported accessibility hierarchy shows the
  macOS StaticText carries its explanation in `value`. The final predicate checks both
  `label` and `value`, with bounded scrolling for smaller Settings viewports.
- `native-v4.xcresult` / `native-v4-summary.json`: **2 native tests pass, zero failures or
  skips**, in **96.327 seconds**: Develop cleanup/relaunch 56.951 seconds and face
  consent/receipt/relaunch 39.377 seconds. Both run against baseline application source
  with the corrected UI-test source. `source-and-binary-sha256.json` records the test and
  tested executable hashes. Successful-run attachment export reports no attachments;
  failed-run hierarchy/screenshots remain in `native-v3-attachments/`.
- Repository validation passes before and after the test changes (`repository.log`,
  `repository-final.log`); `git diff --check` passes.
- Actual persistent STDIO helper probe passes **36 tools**, malformed-input recovery,
  exit zero and zero stderr (`helper.json`, `helper.log`).
- Bundled model verification passes (`model-bundle.log`). The ignored pinned model and
  locked downloader runtime were copied from the main checkout and prepared temporary
  runtime respectively; neither source was modified.
- Restricted development-signature verification initially reports `CSSMERR_TP_NOT_TRUSTED`
  (`signature.log`); verification with approved trust-store access passes deep/strict
  validation (`signature-v2.log`). This is not notarization.

The two native main-thread runtime warnings remain in the final summary and retain the
performance gate. Application source did not change, so this cycle does not repeat or claim
a new integrated unit-suite result. Prior full-suite evidence remains tied to its documented
source revision. No independent agent review or broader native acceptance is claimed.

Environment: arm64 MacBook Pro, macOS **27.0.1 (26A434)**, Xcode **27.0 (27A266a)**.
Tested development app: `/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app`,
version **3.0.0**, build **742**.

Final native command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testReviewedFaceScanRequiresConsentAndRetainsReceipt' \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testDevelopCaptureInspectionPreservesHistoryAndPhotos' \
  -resultBundlePath build/continuation-17/native-v4.xcresult test
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-17/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
python3 -B scripts/ci/validate_model_bundle.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
python3 -B scripts/ci/probe_mcp_helper.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output build/continuation-17/helper.json
codesign --verify --deep --strict --verbose=2 \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
```

## Next implementation work

Connect helper-authenticated native face review/execution only after descriptor-anchored
scanner effects are implemented. Continue Develop native review/execution, embedded owned
effect stages, synchronous rooted commit and watermark authority; signed Whisper provisioning
and broader release qualification remain open. The resolved activation observation no longer
blocks these two local native acceptance cases.
