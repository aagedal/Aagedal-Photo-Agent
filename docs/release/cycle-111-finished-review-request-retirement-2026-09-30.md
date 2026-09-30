# Cycle 111 — finished native review request retirement

Baseline: `ac2a06d`, initially clean. Implementation commit: `0d510cd`. Final application/test
bytes were verified before committing those identical bytes.
State remains **IMPLEMENTING**; no whole 3.0 gate closes. Two bounded implementation agents
owned request storage and native service/model/UI respectively. An independent agent reviewed
the integrated change; the parent owned native workflows, integration, builds, documentation and
commits. App inventory and chat inventory were checked; no other active chat was editing this
checkout. Only owned changes are staged.

## Implemented and decision

- Settings adds a separate confirmed **Remove finished review requests** action. Eligible
  requests must be linked to the exact retained operation, with matching draft/publication kind,
  terminal verified/failed/cancelled/stale outcome, operation creation at or after admission and
  terminal evidence at or after the latest request update. A failed or stale outcome does not
  mean publication succeeded. Every recovery/partial-uncertain outcome remains retained,
  including separately resolved recovery; expiry, missing history and elapsed time prove no
  retirement eligibility. Cancellation recorded after terminal evidence conservatively retains
  the request.
- Operation history is read and validated under its private cross-process archive lock. The
  synchronous callback retains that lock through the request archive transaction, using
  operation-before-request lock order. Cleanup reloads both sources, checks the expected epoch,
  removes only eligible requests and atomically rotates the epoch/disables new legacy creation.
  No operation or recovery history is removed or rewritten. Current and legacy retained retry
  handles keep their original epochs; old retired handles cannot replay through the old epoch
  or legacy omission. No implicit eviction or execution authority is introduced.
- Basic/helper capacity inspection still reports cancelled-before-admission eligibility only.
  Native inspection additionally evaluates finished eligibility. Unavailable/unverifiable history
  produces explicitly unavailable finished eligibility, while preserving cancelled-only capacity
  recovery. Finished mutation refuses unavailable history and never falls back to cancellation
  cleanup. Authorization and cancellation are rechecked before maintenance and fallback.
- Both cleanup dialogs capture the displayed epoch. Confirmation cannot silently bind to a newer
  capacity inspection. Cleanup clears the selected review and both consent types before work,
  blocks execution, refreshes evidence and capacity afterward, and rejects late results after
  navigation. Passive refresh and selection still grant no consent.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Only generated disposable photos and isolated authorization/request/operation stores are used.
Native teardown terminates the test app and removes fixtures/preferences. No user photos,
model downloads, remote writes or Release candidate are used.

- Focused final suite: **108 tests / five suites**, zero failures, 11.953 seconds,
  `build/qa-v3-cycle111-focused-final.{log,xcresult}`. Tests cover eligible outcomes, timing/kind
  mismatch, live/missing/removed/corrupt history, all recovery outcomes, late cancellation,
  contention, unchanged operation bytes, full capacity release, epoch/legacy replay, exact
  authorization, stale confirmation, consent clearing, fallback and late navigation results.
- Serial integrated suite: **3,581 tests / 358 suites**, zero failures, 164.398 seconds,
  `build/qa-v3-cycle111-full.{log,xcresult}`. Twelve previously recorded Thread Performance
  Checker diagnostics and host `MDB_MAP_FULL` diagnostics remain; the performance gate stays open.
- Final actual native workflows: **three tests**, zero failures, 145.795 seconds,
  `build/qa-v3-cycle111-ui-retry.{log,xcresult}`. Final native build passes in
  `build/qa-v3-cycle111-ui-build-final.log`. Generated draft and XMP workflows independently
  perform native approval/execution, inspect finished capacity, cancel cleanup and verify unchanged
  archive bytes, then confirm cleanup and verify the exact removed handle, unchanged other request,
  epoch rotation, disabled legacy creation and unchanged operation/photo/XMP/app-history bytes.
  Relaunch reuses saved authority, waits for the retained request and verifies durable removal and
  preserved evidence. The existing cancelled-before-admission workflow also passes after the two
  separate dialogs and captured-confirmation epochs were introduced.
- Repository validation passes in `build/qa-v3-cycle111-repository-final.log`; final documentation
  whitespace/local-link checks are recorded in `build/qa-v3-cycle111-documentation.log`.
- Actual bundled helper probe: **22 tools**, persistent/pipelined input, malformed-input recovery,
  strict argument refusal and zero stderr; `build/qa-v3-cycle111-helper-final.{log,json}`. SHA-256:
  `97778244399893cecdd5d67deacee3e39b06dff4221967b5b05f487041e4c5cd`.
- Independent source review found no remaining actionable issue. The unavailable-history fallback
  preserves the earlier cancelled-only maintenance behavior. Final test corrections were reviewed.
- Sandboxed Xcode initially refused compiler/package cache writes. Authorized Xcode execution
  resolved that environment limit. The first focused run correctly rejected a fixture's missing
  cancellation epoch after rotation; its explicit epoch was corrected. Native smoke compilation
  required moving two throwing unwraps outside nonthrowing assertion autoclosures. No authority
  guards or test assertions were weakened.
- The first native run timed out enabling XCTest automation before any workflow ran,
  `build/qa-v3-cycle111-ui.{log,xcresult}`. Desktop inventory showed the runner had stopped;
  read-only Finder accessibility eventually responded after 125 seconds. A bounded rerun then
  initialized and passed all three workflows without changing permissions or app settings.
  A final process snapshot verifies no Photo Agent app or UI runner remains.

Exact Xcode invocations are retained at the start of each log. Unit runs use scheme
`Aagedal Photo Agent Tests`, Debug, `platform=macOS`, the shared derived-data path above,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`. Native runs use
`build-for-testing` and `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
120/180-second execution allowances and named workflow selections. XCTest native workflow
results are automated interaction evidence; desktop inventory alone is not manual acceptance.

## Remaining and next actions

1. Continue authenticated IPC/guarded helper commits and shared production face, metadata/Develop
   template and transcription executors. Requests still require explicit native review and consent.
2. Extend retirement to recovery-resolved outcomes only with exact retained recovery receipts and
   preserved recovery authority. Missing operation history, uncertain/unlinked admission and newer
   cancellation evidence stay retained. Qualify physical crash/link-loss, archive deletion/rollback
   and independent-process preference/power-loss behavior separately; archive-local epochs provide
   no external monotonic authority against manually restored or removed storage.
3. Complete iCloud keyword authority, arbitrary export coverage, broader native recovery, signed
   Whisper integration, real Sony/metadata/server/cloud/hardware, accessibility, display/HDR/solar,
   performance, legal/privacy/protected-CI and exact signed-candidate gates. Final user acceptance
   and publication remain separate; llama.cpp stays 3.1.
