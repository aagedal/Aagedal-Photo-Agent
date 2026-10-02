# Cycle 121 — authenticated native transcription review handoff

Baseline: `0fd7871`, initially clean. Implementation: `555c494` (speech teardown) and
`e557d1b` (native handoff). State remains **IMPLEMENTING**. Three sub-agents owned
transport/tests, the read-only request resolver/signed probe, and independent integration review.
The parent owned helper discovery/tool integration, native presentation, builds, desktop inspection,
documentation and commits. Initial and final chat inventory found no other active chat editing this
checkout. No publishing, schedule changes or production photo/root/model changes were made.

## Implemented behavior

- `open_voice_transcription_review` accepts only the original canonical lowercase request UUID and
  epoch. The matching signed helper asks the running app to present that retained intent. Default-off
  automation authority is checked on both sides and after the roundtrip. No consent, provider settings,
  photo paths, audio, transcript text or execution capability crosses the channel.
- A private Unix socket checks same-user kernel credentials and audit-token-selected dynamic code,
  Apple-anchored signatures, team, executable identifiers, and exact current app/helper bundle path
  and code identity in both directions. Static pair validation refuses unsigned, ad-hoc or unpaired
  installations. Hashes in request data grant no trust. No network port or app launch is introduced.
- No-follow retained directory descriptors, owner flock, inode witnesses, private permissions and
  concrete stale-socket refusal protect publication/recovery. Live endpoints and unexpected entries
  are preserved. Messages have a closed canonical schema, 512-byte limit, deadlines and four accepted
  connections. A fixed public greeting follows helper authentication before the helper authenticates
  the app and sends handles. A bounded receipt keeps the connection alive for final app authentication.
  Stop wakes socket IO and invalidates queued UI publication without blocking the main thread on a
  running read-only handler. See [ADR-006](../adr-006-authenticated-native-review-handoff.md).
- The app-side resolver rechecks exact retained epoch/state/intent, expiry and the whole ordered rooted
  preview. Native presentation opens Settings → Automation and inspects the original handles again,
  clearing previous provider review and consent. Late dismissed inspections cannot select a request.
  Initial list refresh preserves either a suspended inspection or its already-completed selection/refusal.
- A legitimately linked request returns only its exact retained operation UUID after locked admission,
  owner, kind, batch and chronology checks. Expired original previews do not erase linked history.
  Cancelled, uncertain admitted, missing-history and changed requests refuse. Helper responses always
  report false consent, execution-start and completion claims; direct helper execution stays unavailable.
- Apple Speech cancellation now covers analysis, finalization and result consumption with one shared
  awaited teardown task. Concurrent cleanup callers wait for the same completion. Provider capacity
  and source security scope remain retained until teardown finishes in each cancellation phase.

## Scope limits

This implements authenticated **review presentation**, with subsequent explicit native provider review,
consent and rooted execution through cycle 120's existing boundary. It does not create a direct helper
executor or serialize consent. Real certificate-signed transport harnesses and actual app UI tests are
separate evidence; the complete installed app/helper-to-review pipeline still needs qualification.
Development signing does not qualify distribution signing/notarization. Synthetic recognition does
not qualify actual Apple/Whisper inference, offline locale completion, signed model lifecycle,
GPU/device behavior, spoken VoiceOver, authentic Sony/server/cloud evidence, physical power-loss
recovery or release readiness. No whole Phase 5A or release criterion closes; no Release candidate
or distribution artifact was built.

## Verification

Environment: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures use generated photo/WAV/relationship bytes, synthetic providers and isolated authority,
request, plan, operation and preference stores. The signed probe creates and removes its own
development-signed harness bundles and private temporary sockets. No signing identity or private
material appears in its report. The 20 frozen application/test/project/probe hashes in
`build/qa-v3-cycle121-source-hashes.json` match the implementation commits.

- Focused verification passes **142 tests / six suites**, zero failures/skips, in **7.272 seconds**
  (`build/qa-v3-cycle121-focused-final2.{log,xcresult}` and `-summary.json`). This includes 17 transport
  tests, real kernel audit-token checks before and after response, exact resolver/history evidence,
  strict helper arguments/private errors, native epoch/dismissal and three gated teardown phases.
- Complete serial integrated verification passes **3,776 tests / 369 suites**, zero failures/skips,
  in **122.359 seconds** (`build/qa-v3-cycle121-full-final.{log,xcresult}` and `-summary.json`).
  Twelve log QoS diagnostics (four summary warnings) and 340 host `MDB_MAP_FULL` messages remain;
  broader performance/environment qualification stays open.
- The production Security-framework/kernel transport probe passes **13 cases** with complete cleanup
  (`build/qa-v3-cycle121-native-auth-final3.{json,log}`). Matching review, exact linked-operation,
  raw-wire and post-refusal recovery succeed. Ad-hoc, unpaired, wrong-identifier and other installed
  pair peers refuse. The production client independently refuses a wrong signed app as
  `unpairedExecutable`, with **zero request bytes** observed by that app. Unsigned process cases are
  explicitly OS launch refusals, not channel qualification. Malformed/partial/timeout raw results
  cannot count as successful negative tests.
- The actual bundled STDIO helper probe passes **31 tools**, persistent/pipelined protocol recovery,
  strict argument refusal and truthful direct-executor boundaries, exit zero and zero stderr
  (`build/qa-v3-cycle121-helper-final.{json,log}`). Helper SHA-256:
  `d3be233a8b7c2a7d3e2168339303498ce606155a1d35598e8fdae179aadb3b3d`.
- All **four final-source native workflows** pass in **131.714 seconds**, zero failures/skips
  (`build/qa-v3-cycle121-ui-final.{log,xcresult}` and `-summary.json`). They cover exact automatic review
  selection with unchanged request bytes/no operation/no draft/no consent; concrete-provider consent
  and verified draft completion; changed-source refusal; and Settings dismissal, retained cancellation,
  saved prefix and relaunch. The invocation fixture exercises presentation only, with authentication
  separately tested above. 10 runtime observations keep broader layout/performance gates open.
- Repository validation and final whitespace checks pass (`build/qa-v3-cycle121-repository-final2.log`).
  All 458 local links across 10 changed Markdown documents pass
  (`build/qa-v3-cycle121-links.json`). Independent source/evidence review found no remaining actionable
  issue in this bounded implementation. All frozen application/test/project/probe hashes remain exact.

Manual computer-use inspection opened the actual Debug app with normal preferences, then Settings →
Automation. Accessibility text and screenshot showed automation off, no authorized roots and readable
private-client availability copy without clipping. No settings were changed. The app was quit before
final unit/native verification. This is read-only layout evidence, separate from synthetic execution
and signed harness evidence; no unrelated app was operated.

Initial sandboxed compilation could not write normal Xcode/package caches; approved normal cache
access completed builds and result extraction. Initial compile/test failures are retained under
`build/qa-v3-cycle121-build*` and `-focused*`: the cleanup closure needed escaping sendability, fixture
helpers needed nonisolated sendability, and fixture canonical paths/history errors and discovery
expectations needed correction. Socket tests also exposed Foundation's physical `/private/tmp` path
normalization. Production lexical validation now retains the physical no-follow descriptor spelling.

Early signed probes `-native-auth{,2,3,4,5}` and `-native-auth-final` retain failed attempts. The disposable
ignored diagnostic harness isolated Darwin's `LOCAL_PEERTOKEN` refusal before accept. The greeting
fixed that boundary, then the real kernel regression exposed token loss after immediate server close
(`-focused-final`, one failure). The receipt fixes that lifetime race while preserving both signature
checks. Final focused/integrated/native/signed results above are authoritative. The initial native run
also passed four workflows in 127.329 seconds, before the final startup-refresh preservation correction.
No application source changed after final verification; only the signed probe gained its independent
wrong-app/zero-disclosure case while integrated testing used the same frozen application source.

Reproduction:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/qa-v3-whisper-lifecycle-derived \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath build/qa-v3-cycle121-full-final.xcresult
scripts/ci/validate_repository.sh
git diff --check
python3 -B scripts/ci/probe_mcp_helper.py \
  'build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output build/qa-v3-cycle121-helper-final.json
python3 -B scripts/ci/probe_native_invocation.py \
  --signing-identity '<explicit compatible local certificate selector>' \
  --work-directory build/qa-v3-cycle121-native-auth \
  --output build/qa-v3-cycle121-native-auth-final3.json
```

Focused selection uses `AutomationNativeInvocationChannelTests`,
`AutomationNativeTranscriptionReviewInvocationServiceTests`, `MCPNativeInvocationToolTests`,
`AutomationTranscriptionReviewModelTests`, `MCPServerCoreTests` and `CaptionVoiceMemoTranscriptionTests`.
Native testing uses the `Aagedal Photo Agent UI Smoke Tests` scheme, serial execution, 120-second
default / 180-second maximum allowances and `-only-testing:` selections for:

```text
testNativeTranscriptionInvocationOpensExactReviewWithoutConsent
testNativeHelperTranscriptionRequiresConcreteProviderConsentAndSavesDrafts
testNativeHelperTranscriptionRefusesChangedSourceAfterConsent
testNativeHelperTranscriptionSurvivesSettingsDismissalAndCancelsRetainedWork
```

## Next work

Qualify the complete actual installed signed app/helper review pipeline. Implement guarded direct
helper execution only through exact fresh native consent, retained rooted authority and durable
operation linkage; preserve non-replay and truthful completion. Qualify actual providers,
offline/device behavior and signed model lifecycle, connect remaining face/template executors and
broaden recovery. Preserve external interoperability/server/cloud/hardware/accessibility,
performance, privacy/legal, remote-CI and exact signed-candidate/user acceptance gates.
