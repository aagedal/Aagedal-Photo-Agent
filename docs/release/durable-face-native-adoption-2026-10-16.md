# Durable face native adoption — 2026-10-16

Continues [durable lifecycle integration](durable-face-lifecycle-integration-2026-10-16.md)
on baseline `ab1a50c`. State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

Settings offers an explicit Review Original Face Request action after authenticated
helper presentation. A scanner-free native model adopts the original durable record,
revalidates its inventory and authority, and presents the existing native review of
scan options and saved-data consequences. It preserves the original request ID,
epoch, digest, preparation/expiry times and reduced remaining lifetime. Repeated
review in the same presentation reuses the app-session intent store.

The service's direct durable preparation bridge uses the existing revocable review
lifecycle. Successful and failed replacements revoke previous review/approval
capabilities. Model preflight and inventory work retain the serial worker. Dismissal,
request replacement, authorization changes and view disappearance cancel preparation
and revoke the session; delayed preparation cannot repopulate a dismissed review.

Durable reviews expose no consent toggles, Start action or replacement folder/options
controls. The model rejects durable starts even if acknowledgements are set directly;
the Settings factory also owns no scanner and has a refusing scheduler. The existing
backend service remains capable of separately consented durable admission for future
integration. This change does not expose helper execution or create operation history,
receipts, face data or thumbnails by adopting a request.

An independent agent implemented the service bridge/tests and reviewed the integrated
model/UI change with no blocking findings. Parent integration owns model tests, Settings
wiring and the signed-helper native regression extension.

## Verification

Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0/build 742.
Evidence directory: `build/face-native-adoption/`. Fixtures use generated disposable
photo bytes and private temporary request/history archives. Ignored pinned AuraFace
and web runtime resources came from the main checkout. The tracked bridge script
remains the baseline version. The restricted initial Xcode invocation could not write
package/compiler caches; the normal-access retry uses development signing.

Focused verification passes **35 tests in three suites**, zero failures/skips, in
1.276 seconds of Swift Testing runtime. Console: `focused.log`; result summary:
`focused-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_23-34-16-+0200.xcresult`.
The command is:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanIntentAdoptionTests' test
```

Integrated verification uses the same built app/test bundle and command configuration,
without `-only-testing` arguments, with `test-without-building`. It passes **4,231 total
tests in 409 suites**: 4,229 passed, zero failures and the two existing opt-in Sony
fixture skips. Swift Testing runtime: 163.749 seconds. Console: `integrated.log`;
summary: `integrated-summary.json`. Result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.16_23-41-48-+0200.xcresult`.
Both summaries report zero runtime warnings. Neither console records Main Thread
Checker or Thread Performance Checker messages. Existing `MDB_MAP_FULL` observations
remain. Concurrent native build preparation means this is regression evidence, not
real-volume performance qualification.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-adoption-module-cache` (`repository.log`). Actual persistent-pipe
helper probing passes all **41 tools** (`helper.json`, `helper.log`), bundled model validation
passes (`model.log`), and completed-app deep/strict development-signature verification
passes with certificate access (`signature.log`). Final native-tested app checks also pass:
`helper-final.json` / `helper-final.log` (41 tools), `model-final.log`, and
`signature-final.log`.

The signed-helper native workflow passes **one test**, zero failures/skips, in
42.926 seconds on 2026-10-17. It performs all **four authenticated helper calls**,
explicitly adopts the original request, verifies no Start/consent/replacement controls,
checks unchanged request/archive/photo bytes and expiry, dismisses and reopens the
original request, and completes existing capacity-maintenance checks plus normal Quit.
`native-final.json` reports passed, cleanup complete, unchanged host preferences and
production sandbox, and no execution submission. Console: `native-final.log`; summary:
`native-final-summary.json`; result: `native-final.xcresult`.

The native command is:

```sh
python3 -B scripts/ci/probe_installed_native_review.py --face-review \
  --app 'build/face-native-adoption/DerivedData/Build/Products/Debug/Aagedal Photo Agent.app' \
  --derived-data-path build/face-native-adoption/DerivedData \
  --result-bundle build/face-native-adoption/native-final.xcresult \
  --log build/face-native-adoption/native-final.log \
  --output build/face-native-adoption/native-final.json
```

The probe initially refused the temporary products path because it requires ignored
repository `build` products/evidence. After rebuilding there, the first executed native
run passed adoption/control/evidence checks but failed dismissal after XCTest
scrolled to the button below the expanded review (`native.log`, `native.json`,
`native.xcresult`; failure screenshot `dismiss-failure.png`). Review and Dismiss now
stay together above expanded details; the final rerun passes. Independent follow-up
review found no dismissal/session race. The 35-test and full regression results precede
this final control-placement-only correction; the final native test and repository
validation (`repository-final.log`) verify that correction. No additional broad
performance or distribution claim follows from this UI result.

Final source/test hashes are in `source-sha256.json`; native app artifact hashes are
in `artifact-sha256.json`. The native summary records one main-thread runtime warning ("This method should not be
called on the main thread as it may lead to UI unresponsiveness."). No root-cause or
warning-remediation claim is made; the performance gate remains open. See
`native-final-summary.json`.

## Remaining work

Descriptor-anchored reset, thumbnail and document effects remain prerequisites to
exposing durable request execution. The next bounded slice is a retained descriptor
capability through `FaceDataFolderLoadService`, staged thumbnail/document publication
through `FaceDataStorageService`, and scanner wiring for thumbnail repair plus periodic/
final saves. Preserve read-only corruption recovery. Reset/deletion then needs descriptor
traversal with accurate partial-commit evidence. Existing rooted draft installation and
Known People package deletion supply patterns; test symlink/directory replacement,
staged-inode swaps, consent withdrawal and postcommit failures before enabling execution. Then connect explicit native scan/reset consent,
start and durable completion-record/history context. Native provider interaction,
real-volume latency, accessibility, Instruments and distribution qualification remain
separate release gates. This bounded review step closes no broad release gate.
