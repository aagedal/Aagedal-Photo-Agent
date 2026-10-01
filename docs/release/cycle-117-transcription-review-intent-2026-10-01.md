# Cycle 117 — transcription review intent and exact native relationship binding

Baseline: `ee19538`, initially clean. Verification used owned dirty changes, now committed as
`038030d` (exact native relationship binding) and `aca596a` (separate transcription review intent).
Final application/project/test hashes match those commits; no source changes followed validation.
State remains **IMPLEMENTING**. The parent owned native
relationship binding, integration, native tests, documentation and commits. One sub-agent owned
the separate durable transcription intent store/helper tools; another owned the native inbox,
model tests and isolated fixture. A third independently reviewed all implementation and tests,
with no actionable findings. Chat inventory found no other active chat editing this checkout.

## Implemented behavior

- Five separate transcription review tools expose capacity, listing, request, inspection and
  pre-admission cancellation. New intent requires a transcription-specific epoch, canonical
  request UUID and retained plan. The ordered photo/metadata/relationship/WAV revisions, root IDs,
  provider options and plan dates are immutable and bound by an intent digest and batch identity.
  Exact retries return retained status, even after expiry, without rereading sources or replaying work.
- `withValidatedPreview` retains every rooted photo reservation, carrier validator and WAV witness
  across the private request publication, then repeats whole-set validation before returning.
  Native inspection compares both the exact retained request and regenerated intent with the plan;
  any drift, cancellation, expiry or authority change refuses the display snapshot.
- The transcription request archive is separate from IPTC requests, with a strict schema, mandatory
  epochs, process-locked replacement and at most 64 records / 1 MiB. It accepts only awaiting-review
  or cancelled-before-admission intent. Unknown admission/linkage/consent fields, future schemas,
  fabricated states, malformed handles and false checksums refuse without overwriting evidence.
  Internal cancelled-only retirement rotates the epoch; old handles cannot target a recreated intent.
  Native capacity cleanup is not exposed yet, and there is no automatic eviction.
- Settings → Automation → Transcription Intent Review lists retained intent and offers read-only
  source revalidation plus explicit cancellation before admission. Ordered plain-text photo paths,
  provider/language/translation/GPU requests and unresolved runtime/model admission are visible.
  Off-main storage work and generation checks suppress late selection, refresh or cancellation
  completions. Failed refresh retains statuses as stale while clearing previous review evidence.
- Native Caption batch consent now binds a bounded no-follow relationship read to raw bytes,
  device/inode, size/mode/link count and nanosecond mtime/ctime. Parse-equivalent rewrites and
  equal-byte replacements invalidate confirmation and pre/post-recognition checks. The witness
  reaches the create-only save transaction and is checked inside the shared photo lease/metadata
  lock around source/WAV validation. Portable SourceImageRevision content semantics stay unchanged.

This milestone grants no provider consent, creates no operation link, runs no inference/download
and saves no transcript from helper review requests. Native Caption transcription remains a
separate explicit consent workflow. Raw native relationship evidence is session-only and does
not establish parity with helper rooted execution or authenticated IPC.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures are generated and disposable; they do not authorize user folders, use user photos or
install providers/models. Commands are retained in build/test logs. Focused verification passes **142 tests / seven suites**, zero failures/skips, in 4.438 seconds
(`build/qa-v3-cycle117-focused-complete.{log,xcresult}` and `-focused-summary.json`). The tests
cover strict handoff schemas/handles, separate IPTC ownership, no-effects intent/retries, epoch
retirement/recreation, drift/authority/expiry refusal, stale native completion suppression and exact
raw relationship refusal at confirmation, during recognition and inside save admission.

The built helper probe passes **30 tools**, persistent/pipelined protocol recovery, strict argument
refusal and honest unavailable execution boundaries, exit zero and zero stderr.
`build/qa-v3-cycle117-helper.{json,log}` records SHA-256
`c87bb540adb8710bf0088f7d8776421542e0345c1be8d6304f0bafd6900a0dc6`.
Final repository validation passes in `build/qa-v3-cycle117-repository-complete.log`.
The complete serial integrated suite passes **3,677 tests / 364 suites**, zero failures/skips,
in **115.206 seconds**, using the final application source. Results are retained in
`build/qa-v3-cycle117-full.{log,xcresult}` and `-full-summary.json`.
Twelve existing QoS diagnostics and 340 host `MDB_MAP_FULL` messages leave broader performance
and environment qualification open. All 19 changed application/project/test source hashes match
`build/qa-v3-cycle117-source-hashes.json`. No Release candidate or distribution artifact was built.
Whitespace checks and all 447 local links across the eight changed documents pass
(`build/qa-v3-cycle117-links.json`).

The first native run passes the existing Caption batch consent/save/relaunch workflow but
reproduces two crashes while accessibility snapshots query the populated inbox. Both crash stacks
show recursive SwiftUI/AppKit label resolution and stack-guard failure; the captured diagnostic
reports are retained in `build/qa-v3-cycle117-ui-crash-{1,2}.ips`. The fix isolates selectable native text behind virtual static-text elements with fixed field
labels and literal evidence values, and contains the surrounding accessibility groups. Independent
review caught an intermediate empty-value regression; it was corrected before final verification.
The final two native workflows pass in **66.429 seconds**, zero failures, with request-ID and exact
ordered path accessibility values verified. Inspection creates no consent, operation or draft;
changed-relationship refusal leaves intent retained and cancellable; cancellation and unchanged
photo/audio/request evidence survive relaunch. `build/qa-v3-cycle117-ui-final.{log,xcresult}` and
`-ui-summary.json` retain that result. The original existing Caption batch consent/save/relaunch
workflow also passes in 35.831 seconds in `build/qa-v3-cycle117-ui.{log,xcresult}`. Both workflows
passed the intermediate structural repair too (`-ui-repaired.{log,xcresult}`). No spoken-VoiceOver
or real-provider inference qualification is claimed. The complete integrated suite above includes the final accessibility repair.

Initial validation diagnostics also caught the fixture Codable isolation, nested Swift Testing
throws-macro expansion, no-follow refusal of noncanonical temporary parents and canonical-path
assertion mismatches. These test-only fixes preserve the refusal contracts; final focused tests pass.

## Remaining and next actions

1. Connect separate epoch-bound transcription admission to exact operation linkage through the
   retained executor's pre-start hook. A kind/count/time-only operation match is insufficient.
2. Bind native provider/model/executable identity and requested options to the exact rooted
   helper intent under whole-set source/metadata/relationship/WAV admission and authenticated IPC.
   The current inbox supplies no execution consent or provider readiness.
3. Add explicit native cancelled-request capacity maintenance with displayed-epoch confirmation;
   qualify actual Apple/Whisper inference, cancellation/relaunch/offline/device behavior and signed
   model lifecycle; connect remaining face-scan/template executors and guarded helper commits.
4. Preserve physical crash/archive-loss, cloud, authentic Sony/metadata/server/hardware,
   accessibility, display/HDR/solar, performance, legal/privacy, protected CI and exact signed-candidate
   gates. Final user acceptance and publication remain separate; llama.cpp stays deferred to 3.1.
