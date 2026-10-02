# Cycle 120 — native transcription consent and rooted execution

Baseline: `63e1552`, initially clean. Implementation: `d5f40cf`. State remains
**IMPLEMENTING**. Two sub-agents owned the execution backend and native review UI/tests; a third
independently reviewed integration. The parent owned retained rooted filesystem authority, exact
Apple locale admission, integration, builds, the desktop, documentation and commits. Chat inventory
found no other active chat editing this checkout. No publishing or schedule changes were made.

## Implemented behavior

- Automation Settings now has separate concrete provider review and unchecked explicit consent.
  Review freezes the exact retained request/epoch/intent, ordered photo batch and installed Apple
  locale or Whisper artifacts/options. Selection and intent inspection grant no execution consent.
  Async changes invalidate consent; unavailable providers refuse without inference or draft effects.
- Confirmation repeats whole-set authority/readiness checks, retains the original rooted photo/folder
  reservations, and durably admits and links one exact operation before scheduling work. Request and operation
  history retain the reserved operation ID, owner, kind and batch identity. Interrupted admission, linked
  requests and terminal history cannot replay after relaunch. Preview expiry is checked before
  admission/linkage; a legitimately running operation does not expire mid-recognition.
- Original source, metadata-directory, WAV and relationship witnesses remain held until terminal
  completion. Full whole-set checks follow awaits and precede recognition/save; lightweight authority
  polling cancels and drains a provider after root/carrier drift or cancellation. No second lease is
  acquired during a retained rooted save. The whole set must have no existing transcript before
  admission, and each install preserves unrelated app JSON and existing metadata.
- Transcript drafts install through the anchored private-directory primitive with exact source,
  XMP and app-carrier checks. Only the operation's verified own draft advances the retained app
  revision. A newly created private directory is retained for every same-folder photo; an externally
  created or replaced directory refuses the original witness. Equal-byte inode replacements refuse.
  Existing transcripts are never silently replaced. Provider output must match reviewed Apple locale
  or Whisper model/build/options/artifact provenance.
- Settings dismissal leaves the retained task running, with global transcription capacity held until
  terminal completion. Native and helper cancellation cooperate with the exact linked operation.
  Completed prefix drafts remain unapproved; unfinished items have no draft. Uncertain installed-byte
  verification reports retained recovery-required evidence and stops the suffix. This does not add a
  rollback-original journal or qualify physical power-loss recovery.

## Scope limits

The native Settings path is connected. The STDIO helper still advertises unavailable direct
execution and unresolved application-session provider identity. Authenticated helper/app invocation
and a direct helper executor remain unfinished. Checksums are corruption evidence, never
authentication. Synthetic Apple/Whisper callbacks and disposable fixtures do not qualify actual
inference, installed-language offline completion, signed model lifecycle, GPU/device behavior,
spoken VoiceOver, authentic Sony/server/cloud evidence or physical crash/archive-loss recovery.
No whole Phase 5A or release-readiness criterion closes and no new Release/distribution candidate
was produced.

## Verification

Environment: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0
build 739. App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Tests use generated photo/WAV/relationship files, synthetic recognition and isolated authority,
request, plan, operation and preference storage. No production photos, authorized roots, models,
provider installation or recipient settings were changed. Final application/test/probe hashes are
retained in `build/qa-v3-cycle120-source-hashes.json` and match the implementation commit.

- Focused verification passes **191 tests / seven suites**, zero failures/skips, in **21.985 seconds**, including four
  concrete/existential dispatch routes and uncertain rooted-save refusal
  (`build/qa-v3-cycle120-focused-final.{log,xcresult}` and `-summary.json`). This run precedes the
  close-on-exec correction; the final integrated suite below covers that same focused scope again.
- Complete serial integrated verification passes **3,746 tests / 366 suites**, zero failures/skips,
  in **118.561 seconds** (`build/qa-v3-cycle120-full-final.{log,xcresult}` and `-summary.json`).
  The log retains 12 Thread Performance Checker QoS diagnostics (four result-summary warnings)
  and 340 host `MDB_MAP_FULL` messages; broader performance/environment qualification remains open.
- Final bundled helper probe passes **30 tools**, persistent/pipelined protocol recovery, strict
  argument refusal and the distinct native/helper executor boundary, exit zero and zero stderr
  (`build/qa-v3-cycle120-helper-final.{json,log}`). Helper SHA-256:
  `a50247504865f88bc7d22a318814b6593544927f49d8e99ec2cf2d74ae5455ba`.
- Repository validation, final whitespace checks and all **453 local Markdown links across eight
  changed documents** pass (`build/qa-v3-cycle120-repository-final2.log` and
  `build/qa-v3-cycle120-links.json`). Sixteen final application/test/probe hashes remain unchanged.
- All **nine final-source native workflows** pass, zero failures/skips, in **332.456 seconds**
  (`build/qa-v3-cycle120-ui-final3.{log,xcresult}` and `-summary.json`). New consent/verified draft
  completion passes in 38.903 seconds, changed-source refusal in 29.198 seconds, and retained
  dismissal/cancellation/prefix/relaunch in 48.233 seconds. Six prior Caption, intent inspection,
  relationship-refusal and confirmed-capacity/epoch workflows also pass. The summary retains 14
  constraint diagnostics and nine XCTest responsiveness warnings; broader layout/performance
  qualification remains open. Functional assertions do not close those gates.

Initial compile/focused failures are preserved in `build/qa-v3-cycle120-build.log` and
`build/qa-v3-cycle120-focused{,2,3}.{log,xcresult}` where created. Corrections covered Swift
sendability/isolation, optional fixture ownership, provenance segment type, exhaustive failure
mapping and a model fixture's invalid queued-to-verified registry transition. Final focused
verification then passed. The first integrated run passed 3,743 tests / 366 suites in 126.205 seconds;
a subsequent test-only regression adds uncertain rooted-save coverage. Final integrated results
above are authoritative.

The first native run retained six passes and three harness failures in
`build/qa-v3-cycle120-ui.{log,xcresult}`: the persisted operation ID belongs inside the admission
record, the Automation title was ambiguous after reopen, and an overlaid main window obstructed
Settings scrolling. The corrected harness scopes the actual Settings window and Sidebar, explicitly
foregrounds its observed titlebar and checks the real terminal operation/admission. It strengthens
completion/cancellation/relaunch assertions and changes no product behavior, assertion contract or
timeout. The next native run exposed a concrete service-call dispatch defect: synchronous throwing
inspection/cancellation methods competed with the protocol's asynchronous throwing defaults.
The compiled fixture referenced the default extensions, while compiled protocol witnesses correctly
reached the concrete methods. The symbol inspection is retained in
`build/qa-v3-cycle120-dispatch-review.txt`. Explicit async signatures and concrete/existential
regressions correct concrete overload selection; the native
cancellation case retains the same terminal archive and saved-prefix checks. Final native results
above are authoritative. The intermediate run remains in
`build/qa-v3-cycle120-ui-final.{log,xcresult}` (eight passes, one cancellation failure in
324.494 seconds). Final review additionally found that duplicating a retained private-directory
handle cleared close-on-exec. `F_DUPFD_CLOEXEC` now preserves descriptor noninheritance. The
subsequent native run was deliberately stopped before completion to rebuild that correction;
its partial result is retained in `build/qa-v3-cycle120-ui-final2.{log,xcresult}` and is not a
passing suite. Final integrated and native verification use the corrected frozen source.

Before the final async-dispatch and descriptor corrections, manual computer-use inspection opened the actual Debug app with normal preferences,
opened Settings → Automation and scrolled through the transcription review area. The default-off,
no-root state and disabled review refresh refusal were observed in native accessibility text and a
screenshot; labels and spacing remained readable. This is layout/read-only evidence, separate from
synthetic native execution tests. Those corrections change no visual layout. The manually launched built app was quit before native testing;
no unrelated application was operated. Native tests terminate their fixture app during teardown.

Xcode verification and result-summary extraction used normal approved compiler/package/report
cache access. The initial sandboxed build could not write those caches. No sandbox or permission
bypass was used. No application source changes followed final verification. Independent review
found no remaining actionable issue in the bounded implementation; final evidence review is
complete for the final source and evidence. No Release candidate, notarization or distribution artifact was built.

Reproduction commands (individual selected tests appear in the native log):

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/qa-v3-whisper-lifecycle-derived \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath build/qa-v3-cycle120-full-final.xcresult
scripts/ci/validate_repository.sh
git diff --check
python3 -B scripts/ci/probe_mcp_helper.py \
  'build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output build/qa-v3-cycle120-helper-final.json
```

The focused invocation selects `MCPNativeVoiceTranscriptionBindingServiceTests`,
`AutomationTranscriptionReviewModelTests`, `MCPVoiceTranscriptionPlanStoreTests`,
`AutomationVoiceTranscriptionBatchTests`, `MCPVoiceTranscriptionReviewRequestStoreTests`,
`MCPServerCoreTests` and `CaptionVoiceMemoTranscriptionTests`. The final native invocation uses the
`Aagedal Photo Agent UI Smoke Tests` scheme and 120-second default / 180-second maximum test
timeouts and result bundle `build/qa-v3-cycle120-ui-final3.xcresult`. It adds
`-only-testing:Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/<name>` for:

```text
testNativeHelperTranscriptionRefusesChangedSourceAfterConsent
testNativeHelperTranscriptionRequiresConcreteProviderConsentAndSavesDrafts
testNativeHelperTranscriptionSurvivesSettingsDismissalAndCancelsRetainedWork
testNativeTranscriptionBatchConsentDraftRefreshAndRelaunch
testNativeTranscriptionBatchRefusesUnavailableProviderAndChangedWAV
testNativeTranscriptionCancelledCapacityPreservesIntentAndRelaunches
testNativeTranscriptionCancelledCapacityRefusesChangedConfirmationEpoch
testNativeTranscriptionReviewInspectionCancellationAndRelaunch
testNativeTranscriptionReviewRefusesChangedRelationshipAndRetainsCancellation
```
The uncertain rooted-save and concrete/existential dispatch tests also run in the final complete suite.

## Next work

Implement authenticated helper/app invocation and guarded direct helper execution using this exact
native consent, retained rooted session and durable operation boundary. Qualify actual providers,
offline/device behavior and signed model lifecycle; connect remaining face/template executors and
broaden recovery. Preserve authentic interoperability/server/cloud/hardware/accessibility,
performance, privacy/legal, remote-CI and exact signed-candidate/user acceptance gates.
