# Durable face native execution — 2026-10-17

Continues [anchored reset](durable-face-anchored-reset-2026-10-17.md) on clean
baseline `69ef6e7`. Verification covers this task's source/test changes over that
baseline; the recorded hashes identify the tested files. State remains IMPLEMENTING;
the broad audit remains 66 of 75.

## Implemented boundary

Settings can explicitly adopt an authenticated original face request, review its
exact photo inventory/options and grant separate native scan/reset consent. Only the
native Start action consumes that consent. The original request, snapshot and wall/
continuous expiry remain unchanged. No helper scan-start tool or serializable native
approval is introduced.

The app owns one face scanner and Activity history, shared by Browser and Settings.
Settings uses the existing native operation adapter and retained anchored scanner,
including one-way admission, actual managed owner linkage, exact-task cancellation
and drain. Closing/replacing the review withdraws its effect permission immediately;
late completion cannot repopulate the dismissed review. Re-adoption is disabled while
the visible operation drains, and the shared scanner refuses overlapping scan work.

Review retains the original durable request store independently of the preparation
window. After worker drain, receipt publication reads its current linked record and
checks the original request/epoch/hash, admission, operation, managed owner, history
location and actual terminal registry record. It does not recapture changed inventory
or apply review expiry to completed effects. Missing or substituted evidence preserves
the terminal operation/receipt for inspection and refuses completion publication or
replay.

Retained and Browser scans use the same managed receipt destination. Historical
inspection displays original request/admission correlation without restoring consent.
Partial reset presentation describes the exact removal prefix instead of implying a
complete reset. Face operation recovery guidance describes saved face data, thumbnails
and possible partial reset rather than metadata drafts.

## Review and verification

Independent review covered native admission/completion, shared ownership, withdrawal,
new unit coverage and signed native qualification. It found an undefined UI fixture
receipt variable, corrected before native compilation, and two test gaps: populated
reset and history after relaunch. The native test now covers both.

Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0/build 742.
Generated disposable photo/storage fixtures;
ignored pinned AuraFace and web runtime resources copied from the main checkout.
Evidence is in `build/face-native-durable/`.

The focused run passes **53 tests in three suites**, zero failures/skips, in 2.278
seconds of Swift Testing runtime. Its result summary reports zero runtime warnings.
The first integrated run passes **4,266 total tests in 410 suites**: 4,264
passed, two existing opt-in Sony fixture skips and zero failures, in 136.844 seconds.
Its summary reports zero runtime warnings. The console retains existing `MDB_MAP_FULL`
observations; these runs do not establish real-volume performance qualification.

The focused command is:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPNativeFaceScanReviewServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' test
```

The integrated command removes all `-only-testing` arguments. Results:
`focused.log`, `focused-summary.json`, `integrated.log`, `integrated-summary.json`.
Result bundles:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_17-58-54-+0200.xcresult`
and
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_18-04-23-+0200.xcresult`.
The first restricted build refused compiler/package cache access; normal-access
verification succeeded. The integrated run includes the final shared receipt destination
and Activity history recovery test.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-native-module-cache` (`repository.log`). The persistent-pipe
helper probe passes all **41 tools** (`helper.json`, `helper.log`); the bundled model
check passes (`model.log`). Native probe parser/result checks pass seven tests
(`probe-tests.log`).

The native probe initially refused the temporary products location; its isolated
DerivedData directory is now under the ignored repository evidence tree. The first
actual native run reached adoption, but the test incorrectly searched for CheckBox
instead of the Settings Switch accessibility role. Generic identified-control selectors
correct that fixture. The second run reached both consents and Start; its saved capture
still shows enabled Start, unchanged consent and no status after clicking. This state
precedes scanner admission. The test also read a missing status without an existence
guard, producing a misleading snapshot-type diagnostic.

The native inventory's zero-height ScrollView now has an explicit bounded height;
Start and Dismiss use explicit button styles in the grouped Settings Form. The next
run reached admission and presented a correctly linked recovery receipt: three files
processed, two failures and committed reset/document evidence. The transcription fixture
had intentionally supplied two text files named `.jpg`. The optional face fixture now
creates valid JPEGs before its original request is captured; transcription-only fixtures
retain their previous bytes. Terminal-failure predicates now fail promptly with status.

The following run passed scan completion, exact admission/receipt checks, populated reset,
source-byte preservation and relaunch persistence. History inspection then correctly
refused a `/tmp` symlink path introduced by the test's Foundation path resolution on
relaunch. The fixture now physically resolves its existing parent and appends the receipt
directory without resolving that leaf. Production no-follow storage policy is unchanged.
Saved unsuccessful attempts remain in `native*.xcresult`, matching JSON/log files and
exported attachment directories. They are not counted as successful qualification.

The final signed native probe **passes one test, zero failures/skips**, in **49.452 seconds**.
All four actual helper calls preserve presentation-only acknowledgements and reject stale
epochs. The sandboxed runner then grants separate native scan/reset consent, starts once,
verifies the original linked request/admission/operation, all three processed photos and
exact populated reset removal paths, preserves original photo/metadata bytes, relaunches,
reopens the same managed receipt and displays original request correlation without Start
or restored consent. Normal Quit, listener teardown and fixture cleanup pass. Evidence:
`native-5.json`, `native-5.log`, `native-5-summary.json`, `native-5.xcresult`. Command:

```sh
python3 -B scripts/ci/probe_installed_native_review.py --face-execution \
  --app 'build/face-native-durable/DerivedData/Build/Products/Debug/Aagedal Photo Agent.app' \
  --derived-data-path build/face-native-durable/DerivedData \
  --result-bundle build/face-native-durable/native-5.xcresult \
  --log build/face-native-durable/native-5.log \
  --output build/face-native-durable/native-5.json
```

The native summary records **two runtime warnings**: a user-initiated/utility QoS wait
and a main-thread responsiveness warning. Their root cause is not established here;
performance qualification remains open. These are distinct from test failures.
The probe conservatively reports unconfirmed effects on failed UI runs, timeouts or
unavailable result summaries rather than inferring no execution. Independent follow-up
review found that exception-path reporting gap; finalization now covers it.

The native-tested candidate passes its final **41-tool** persistent-pipe probe,
bundled model validation and deep/strict development-signature verification
(`helper-final.json`, `helper-final.log`, `model-final.log`, `signature.log`). The final
repository check passes (`repository-final.log`). The final current-source regression
passes **4,266 total tests in 410 suites**: **4,264 passed**, two existing opt-in Sony
fixture skips and zero failures, in **130.450 seconds**. Its summary reports zero runtime
warnings. This run includes the final Form layout/actions and valid JPEG test fixture.
Console: `integrated-final.log`; summary: `integrated-final-summary.json`; result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_18-34-09-+0200.xcresult`.
The command is the same unfiltered configuration shown above. Final `git diff --check`
passes. Source/test and artifact hashes are recorded in `source-sha256.json` and
`artifact-sha256.json`; the qualified native executable matches its recorded hash.
No distribution-signature, performance or final-release acceptance is claimed.

## Remaining work

Actual provider/device interactions, real-volume performance, accessibility,
Instruments and distribution qualification remain separate gates. Continue the
managed Develop native review/execution and physical commit authority work in the
release readiness plan. Historical receipt inspection is archived evidence, not a
fresh assertion about current photos, saved data or request/registry availability.
