# Cycle 119 — native transcription provider and rooted session binding

Baseline: `42d86af`, initially clean. Implementation is committed as `dc66d58`; all nine
application/test/project hashes match that commit and the verified final source. State remains
**IMPLEMENTING**. One sub-agent owns
provider snapshots/tests, another owns the rooted bridge/tests, and a third independently
reviews the integrated source. The parent owns batch-service accessors, intent validation,
project registration, builds, evidence, documentation and commits. Chat inventory found no
other active chat editing this checkout.

## Implemented behavior

- Immutable session-only provider evidence retains the exact intent digest and concrete Apple
  locale or Whisper configuration. Language/translation/GPU options must match. Curated/custom
  classification comes from the explicit native choice; filenames, hashes and identifiers do
  not establish trust. Whisper pins both artifact URLs, byte counts and SHA-256 values, build/
  model identifiers and timeout. Complete intent schemas and bounded configuration metadata
  are validated. The snapshot is never persisted and performs no effects or readiness checks.
- A separate read-only native bridge prepares the original ordered native batch, rechecks
  exact retained request/epoch/state/intent and the rooted plan, and repeats the checks after
  asynchronous capture/readiness. Revalidation retains the original batch and provider.
  Rooted whole-set source/metadata/relationship/WAV reservations, anchored carrier witnesses,
  ancestor checks, authorization generation and expiry guards remain active through publication.
- Under those reservations the bridge uses bounded no-follow reads to reproduce rooted photo/
  WAV revision and device/inode tokens and compare native resource identity, size, date and
  content hash. Exact native relationship bytes and association are checked again. Equal paths
  and equal-byte replacements cannot substitute the original retained rooted files.
- Whisper rechecks the frozen provider's artifact authorization before every readiness handoff.
  Apple has an explicit production availability callback requiring the exact installed locale;
  tests inject deterministic availability. No callback downloads assets or requests permission.
  Read-only batch revalidation creates no operation, inference or transcript draft.

## Scope limits

This is an internal read-only session binding API. It has no production inbox caller and does
not connect the binding to durable operation admission, provider execution consent or an
authenticated helper/app invocation. The helper continues to advertise unavailable execution
and unresolved application-session provider identity. Checksums remain corruption evidence,
never authentication. Deterministic Apple/Whisper callbacks and disposable fixtures do not
qualify actual inference, supported-client consent, offline/device behavior, spoken VoiceOver,
physical crash/archive-loss recovery or the wider 3.0 release gates. No whole Phase 5A criterion
closes and no new Release/distribution candidate is produced.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
New binding fixtures use disposable generated photo/WAV/relationship files and isolated authority,
request, plan and operation storage. No production photo roots, provider/model installation or
recipient configuration was changed. Source hashes are retained in
`build/qa-v3-cycle119-source-hashes.json`; every hash matches `dc66d58` and final source.

- Debug app build passes (`build/qa-v3-cycle119-build.log`).
- Final focused verification passes **204 tests / ten suites**, zero failures/skips, in
  **8.645 seconds** (`build/qa-v3-cycle119-focused-final.{log,xcresult}` and `-summary.json`).
  Coverage includes provider/classification/options mismatches, complete malformed intent,
  bounded artifact identity, ordered rooted/native binding, all carrier and equal-byte replacement
  drift, request/task cancellation, already-admitted refusal, expiry after readiness, failed/renewed
  artifact authorization and whole-set utility-executor reservations. Read-only fixtures verify
  unchanged request/plan bytes and absent operation/draft/inference effects.
- Complete serial integrated verification passes **3,722 tests / 366 suites**, zero failures/skips,
  in **103.869 seconds** (`build/qa-v3-cycle119-full.{log,xcresult}` and `-summary.json`).
  Twelve existing QoS diagnostic emissions (four distinct result-summary warnings) and 340 host `MDB_MAP_FULL` messages leave broader performance/
  environment qualification open. These observations do not close a release gate.
- Two actual native Caption workflows pass in **60.283 seconds**, zero failures/skips
  (`build/qa-v3-cycle119-ui.{log,xcresult}` and `-summary.json`): consent/Cancel preservation,
  editable draft refresh and relaunch (**32.658 s**), and unavailable-provider/changed-WAV refusal
  (**27.625 s**). They use isolated synthetic recognition and disposable fixtures, preserve source/
  WAV/relationship bytes and existing metadata, and grant no helper authority. There is no new
  production UI for the internal binding, and no real Apple/Whisper inference claim. The native
  summary retains two responsiveness warnings; broader performance qualification remains open.
- Built helper probe passes **30 tools**, persistent/pipelined protocol recovery, strict argument
  refusal and honest unavailable execution, exit zero and zero stderr
  (`build/qa-v3-cycle119-helper.{json,log}`). Final helper bytes match SHA-256
  `9218fc851a3ec63ba7477dbaeec07deba480d55b45d11a203740ecd900f1f24a`.
- Repository validation, independent source/evidence review and final whitespace checks pass.
  All **440 local Markdown links across five changed documents** resolve; retained checks are
  `build/qa-v3-cycle119-repository-final.log` and `build/qa-v3-cycle119-links.json`.

Initial focused verification found two fixture assumptions, preserved in
`build/qa-v3-cycle119-focused.{log,xcresult}` and `-summary.json`: Foundation canonicalizes the
concrete `en_Latn_US` locale to `en_US`, and the rooted reader canonicalizes this fixture's
`/private/tmp` alias to `/tmp`. The corrected locale characterization retains region and actual
nondefault-script mismatch coverage; the path assertion now compares directly with the exact
ordered retained intent. Production behavior and strict identity checks were unchanged. Two final
cancellation/admitted-state tests were added before the final focused compilation. The final-source
run above is authoritative. No assertion, timeout or refusal contract was relaxed.

Native verification required normal approved Xcode compiler/package cache access. Native result
summary extraction also required its normal report cache; the sandboxed extractor could not write
there. No permission or sandbox workaround was used. No source changes followed final verification.
Independent review finds no remaining actionable issue in the bounded source/evidence scope.
No Release candidate, notarization or distribution artifact was built.

Reproduction commands (exact invocations also appear at the beginning of test logs):

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/qa-v3-whisper-lifecycle-derived \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath build/qa-v3-cycle119-full.xcresult
scripts/ci/validate_repository.sh
git diff --check
python3 -B scripts/ci/probe_mcp_helper.py \
  'build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output build/qa-v3-cycle119-helper.json
```

The focused invocation adds `-only-testing:Aagedal Photo Agent Tests/<suite>` for
`AutomationVoiceTranscriptionProviderBindingTests`, `MCPNativeVoiceTranscriptionBindingServiceTests`,
`AutomationVoiceTranscriptionBatchTests`, `AutomationTranscriptionReviewModelTests`,
`MCPVoiceTranscriptionReviewRequestStoreTests`, `MCPVoiceTranscriptionPlanStoreTests`,
`AutomationOperationRegistryTests`, `AutomationOperationExecutionCoordinatorTests`, `MCPServerCoreTests`
and `FFmpegWhisperTranscriptionProviderTests`. The native invocation substitutes the
`Aagedal Photo Agent UI Smoke Tests` scheme, enables 120-second default / 180-second maximum test
timeouts, and selects `CoreWorkflowSmokeTests/testNativeTranscriptionBatchConsentDraftRefreshAndRelaunch`
and `CoreWorkflowSmokeTests/testNativeTranscriptionBatchRefusesUnavailableProviderAndChangedWAV`.

## Next work

Connect this exact binding to explicit native provider review/consent and durable reserved-operation
admission under rooted authority. Implement authenticated invocation and guarded helper execution;
qualify actual Apple/Whisper inference and signed model lifecycle. Remaining face/template executors,
authentic interoperability/server/cloud/hardware/accessibility, privacy/legal, remote-CI and exact
candidate acceptance gates remain open.
