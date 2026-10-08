# Whisper corrupt-model recovery — 2026-10-08

Baseline: `a9f309f`, initially clean. This bounded continuation addresses the
journalistic workflow plan's Whisper model removal/recovery criterion. State remains
**IMPLEMENTING**; no complete provider, distribution or release gate closes.

## Behavior

On a fresh launch, size/hash-invalid regular cached weights previously failed
installed-model verification and hid Remove Downloaded Model. Settings now exposes
removal for those corrupt weights while offering Download Replacement for
replacement (see the follow-up below). Corruption never satisfies installed/readiness checks, creates an
artifact receipt, or enables a transcription provider. Unsafe-storage errors do not
advertise corrupt-model recovery.

A failed or cancelled replacement retains the previous local file's recovery
controls without restoring execution authority. Failed removal rechecks presence,
retains recovery when corruption remains, and preserves the original removal error.
Successful removal clears recovery. Model selection clears the previous model's
recovery state, and delayed reconciliation refuses publication into a new generation.
The download service's existing descriptor-bound verification, replacement and removal
remain the filesystem authority; this UI state grants no path access.

## Verification

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a). Tests use disposable
fixture directories, isolated preferences and tiny generated model bytes. Native
coverage uses the existing isolated Whisper model-root launch argument and generated
photo/WAV/transcript fixtures. The ignored reviewed AuraFace source package was copied
from the main checkout into this worktree to satisfy the required bundled-model build.

The first sandboxed build could not resolve GitHub. A copied local SourcePackages
cache avoided network fetches; Xcode still required approved access to its normal
compiler/package caches. Pinned resolution used `-disableAutomaticPackageResolution`
and `-skipPackageUpdates`. No package pins changed.

Before the behavior change, the lifecycle suite reproduced five expectation failures
for missing corrupt-model recovery controls (15 declared tests / one suite). The next
focused run exposed one stale corrupt-removal reconciliation failure; a generation
check fixes it. Logs are in `build/continuation-whisper/red.log` and `focused.log`.

Final focused verification passes **57 declared tests / three suites**, zero failures,
0.405 seconds (`focused-final.xcresult`, `focused-final.log`). Cases include real
size/hash-invalid filesystem fixtures, offline replacement preserving exact corrupt
bytes, safe removal preserving unrelated files, failed removal, and both successful
and corrupt delayed reconciliation after a model change.

The first native run observed the new Remove control, then stopped on stale baseline
assertions for an editor AX value and absent Caption language control. Tests now read
selectable transcript text from the display descendants and recognize the current
language picker; standalone approval is also correctly checked for absence. The
corrupt-model native workflow then passes in **58.528 seconds**
(`native-final.xcresult`, `native-final.log`). Four app launches prove corrupt
weights persist until explicit removal, removal succeeds, and the next launch has
no installed model/error/readiness. Photo/WAV/relationship/transcript bytes remain
unchanged. The adjacent explicit-download workflow passes in **26.343 seconds**
(`native-explicit-final.xcresult`, corresponding log), preserving empty-cache/no
automatic-transfer behavior and current Caption/Settings presentation. Its earlier
run stopped on the stale standalone approval-button assertion; `native-final.log`
retains that failure. These are two passing distinct workflows, not a claim that
the combined native run passed.

The tested Debug app is `build/continuation-whisper/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 741. Dirty-source identity relative to the baseline is recorded
in `build/continuation-whisper/source-sha256.txt`. No final Release candidate is built.

Repository validation and whitespace checks pass (`repository-complete.log`).

The first integrated run failed in the existing capture-date/title Import test:
it inherited persisted file-type filtering, produced no groups, and indexed an empty
array, crashing the host. The test now explicitly admits its JPEG, restores the
previous filter, and requires the first group before inspecting its title. Production
Import behavior is unchanged. All **21 ImportViewModel tests pass**, 2.927 seconds
(`import-final.xcresult`, `import-final.log`). `full.xcresult` and `full.log` preserve
the unsuccessful first run. Final integrated regression passes overall: **3,863 passed, two skipped, zero failed
out of 3,865 tests**, across 384 suites in 123.188 seconds (`full-final.xcresult`,
`full-final.log`, `full-summary.json`). The skipped cases require opt-in production
Sony fixtures; this run provides no new authentic-Sony qualification. Existing host `MDB_MAP_FULL` and runtime diagnostics remain separate
from performance/device qualification. Final source hashes match the retained record.

## Commands

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath build/continuation-whisper \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/ManagedWhisperSetupModelTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDownloadServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FFmpegWhisperArtifactAdmissionServiceTests' \
  -resultBundlePath build/continuation-whisper/focused-final.xcresult
# Integrated regression: same command without the three -only-testing filters,
# using -resultBundlePath build/continuation-whisper/full-final.xcresult.
# Native recovery and explicit-download tests use the UI Smoke Tests scheme:
# -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testManagedWhisperRefusesCorruptCachedModelAcrossRelaunch'
# -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testManagedWhisperUsesSettingsAndWaitsForExplicitModelDownload'
scripts/ci/validate_repository.sh
git diff --check
```

## Remaining work

This validates recovery of invalid local weights, not curated-model distribution
signatures, update/rollback across releases, representative inference quality,
GPU/device qualification, spoken VoiceOver or final signed-candidate acceptance.
The follow-up below adds bounded CPU offline and real-model persistence evidence.
Production face/template/IPTC automation executors and broader release gates remain
in the owning plan and coordinator handoff. No release or remote change is published.


## Settings and real-model follow-up

The picker now separates **Downloaded Models** from **Available to Download**, shows
local inventory counts and selected-model availability, and explains verification on
selection. Inventory is a read-only, descriptor-bound metadata scan of catalog files:
no download or hashing starts to populate the groups. Corrupt regular weights remain
listed locally but cannot grant readiness. Symlinked/hardlinked or unsafe leaves are
excluded; unsafe roots report an error. Successful install/removal updates the groups,
and delayed inventory cannot overwrite a newer snapshot or completed mutation.

Corrupt weights expose **Download Replacement**, recovery help and explicit removal.
Real filesystem tests cover successful verified replacement, cancelled replacement
preserving the original bytes, partial-file cleanup and readiness after a fresh setup
instance. A genuine replacement/admission test also exposed Foundation shortening a
physical `/private/var` cache path to the `/var` alias. The service now returns the
physical path obtained from its retained directory descriptor with `F_GETPATH`; strict
artifact admission continues to refuse linked components.

Follow-up focused verification passes **63 tests / three suites**, zero failures,
0.433 seconds (`build/continuation-whisper-followup/focused-physical.xcresult` and log).
Earlier logs retain the compile assertion and path-expectation failures corrected
before this passing run.

### Actual Base model

A read-only copy of the user's existing Base download matches the catalog exactly:
147,951,465 bytes, SHA-256
`60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`.
The original cache was not modified. Public generated speech (7.421 seconds, 16 kHz
mono WAV) has SHA-256
`eba04c12be2073f1c6d04461553a7f34a67138f3c568ce8b236e6dd73dd3e0c8`.
The bundled FFmpeg SHA-256 is
`027cd7187fdcc8d0aab6461ab2d9a98267c71ec33c269e0b2fc9ee68ecb13d8f`.

The exact production runner/provider/parser/provenance harness passes two CPU cases
(explicit English and automatic language) under `sandbox-exec` network denial,
in separate process launches. Each produces three segments, validates exact artifact
provenance and its JSON round trip, and leaves no job directory or FFmpeg process.
Elapsed times are 2.295 and 3.164 seconds. A socket probe independently confirms
network attempts fail with EPERM. Evidence is `offline-final.json`,
`offline-policy.json`, `offline-wrapper.sh` and `offline-provider/` under
`build/continuation-whisper-followup/`. An initial attempt sandboxing the entire probe
orchestrator denied its `/bin/ps` cleanup inspection; the corrected run applies the
profile to the provider and its FFmpeg child while inspecting cleanup outside it.
This qualifies two cases, not the probe's entire nine-case matrix.

The combined native run passes **three tests**, zero failures/skips, 116.913 seconds
(`native.xcresult`, `native.log`): corrupt-model recovery, empty-cache explicit
download behavior, and actual pinned-model transcription/persistence. The actual-model
case passes in 31.045 seconds. It uses the bundled provider without injected inference,
saves a nonempty transcript with exact model identity and CPU provenance, relaunches,
verifies readiness without download, and confirms identical retained sidecar bytes and
visible text. Photo/audio/relationship and model bytes remain unchanged. Network denial
is enforced in the separate provider harness; it is not claimed for this native run.

To repeat the native actual-model case, supply `TEST_RUNNER_APA_NATIVE_WHISPER_MODEL`
and `TEST_RUNNER_APA_NATIVE_WHISPER_AUDIO` to `xcodebuild test` with the UI Smoke Tests
scheme and the `testPinnedWhisperTranscribesAndPersistsAcrossRelaunch` filter. It skips
when those local fixture paths are not supplied; this recorded run supplied both and
executed it. The production model is copied into the isolated test root.

### External analysis source

Image Analysis's external verification tools now also link directly to Google's
[SynthID Detector](https://synthid.com/) under Provenance and watermarks, replacing
the Gemini link. The help documentation includes the direct link. Opening it does not upload
the current image. The external results remain supporting evidence outside the app's
report reproducibility boundary.

Follow-up integrated regression passes **3,869 tests, two opt-in Sony skips,
zero failures**, out of 3,871 tests across 384 suites, 135.450 seconds
(`full.xcresult`, `full.log`, `full-summary.json`). Repository validation and whitespace
checks pass (`repository-final.log`). This run includes the new SynthID entry;
the subsequent user-requested removal of the redundant Gemini entry is a link-only
change checked by a final Debug build (`build-final.log`). Native checks preceded
the external-link edit; their scope is the Whisper changes. Final Swift source
identity is retained in `source-sha256.txt` in the same follow-up directory. No signed-model distribution, GPU, broader hardware or final release gate
is closed by these bounded checks.
