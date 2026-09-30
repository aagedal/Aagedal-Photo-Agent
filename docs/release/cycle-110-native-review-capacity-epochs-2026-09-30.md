# Cycle 110 — native review capacity and request epochs

Baseline: `120f3a3`, initially clean. Implementation commit: `7d3bc47`. Final source was tested
before committing identical application/test bytes. State remains **IMPLEMENTING**; no whole 3.0 gate closes. Two bounded implementation
agents owned the store and native UI/service; an independent reviewer inspected the integrated
change. The parent owned helper protocol, native fixtures/workflows, integration, documentation
and commits. No other active chat was editing this checkout; no unrelated work was staged.

## Implemented and design decision

- Schema 2 binds new helper intents to a durable archive epoch. Explicit
  `get_native_review_request_capacity` initializes or migrates private coordination storage and
  returns the epoch/capacity; its tool annotation correctly describes a possible mutation.
  It grants no consent and writes no photo metadata. Passive native list/status reads never
  initialize or migrate storage. Strict version-1 archives remain readable, and mutation migrates
  them without changing their records. Older helpers reject schema 2 rather than overwrite it.
- Settings exposes **Review request capacity**, then a separate confirmed **Remove cancelled
  review requests** action. Under the same private cross-process transaction, cleanup removes
  only requests cancelled before admission, rotates the epoch and disables new epochless creation.
  Expected-epoch comparison refuses stale cleanup snapshots. Active, admitted, uncertain and
  linked records remain intact, including original timestamps, epochs and cancellation handles.
  The archive still retains at most 256 records; linked-terminal removal is intentionally outside
  this bounded change and remains unfinished release work.
- New helper creation checks the original epoch inside the archive transaction after plan/source
  validation. Exact retained retries use their original epoch even after rotation; legacy retained
  retries omit it. The schema permits legacy omission, but new epochless creation is refused.
  Removed intent cannot retry its old epoch or use the legacy path. Clients must never silently
  resubmit retired intent under a new epoch; a separately requested new intent requires a new ID
  and current epoch. Epoch rotation grants no execution authority.
- Status, cancellation, native admission and uncertain-submission transitions compare the exact
  original epoch. Reusing a UUID deliberately under the current epoch cannot make an old helper
  handle or cached native consent act on that new record. Atomic admission/cancellation and
  uncertainty marking close validation/rotation races; linked operations cannot be retired by
  this cleanup. Native execution and failure paths carry the captured request epoch.
- Capacity work has independent task/generation identity. Confirmation clears current native
  review and both consent types, blocks execution during cleanup, refreshes retained evidence
  afterward and discards late navigation completions. Passive cancellation/retirement refresh
  invalidates stale idle consent. Exact enabled authorization is rechecked before maintenance.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Only generated disposable photos and isolated authorization/request/operation stores are used.
Native teardown terminates the test app and removes fixtures/preferences. No user photos,
model downloads, remote writes or Release candidate were used.

- Final serial integrated suite: **3,572 tests / 358 suites**, zero failures, 155.607 seconds,
  `build/qa-v3-cycle110-full-final.{log,xcresult}`. All epoch, migration, replay, malformed-argument,
  authorization, stale-native-consent, cancelled-only cleanup and preserved-evidence regressions pass.
  Twelve Thread Performance Checker diagnostics and previously observed `MDB_MAP_FULL` host
  diagnostics remain; the performance/release gate stays open.
- Final actual native workflows: **three tests**, zero failures, 117.071 seconds,
  `build/qa-v3-cycle110-ui-final.{log,xcresult}`; build evidence is
  `build/qa-v3-cycle110-ui-build-final.log`. Draft and XMP cases verify separate native consent,
  operation linkage/outcome and exact photo/carrier evidence through relaunch. Cleanup verifies
  cancelled intent, explicit capacity inspection, Cancel leaving archive bytes unchanged, separate
  confirmation removing exactly that record, epoch rotation, preserved other request identity,
  absent operation/XMP/app-history writes and unchanged photo bytes. Its final relaunch reuses the
  saved authorization/archive and waits for the retained list before checking exact archive bytes
  and the removed handle's absence. Native teardown removes fixtures/preferences and stops the app.
- Pre-final-schema focused run: **144 tests / five suites**, zero failures, 9.453 seconds,
  `build/qa-v3-cycle110-focused-final.{log,xcresult}`. The final full run above additionally covers
  the frozen native model tests and final optional-epoch schema/malformed-epoch assertions.
  The preceding integrated run also passed 3,572 tests, and the preceding three native workflows
  passed; final evidence is the named final logs above.
- Actual bundled helper probe: **22 tools**, strict argument refusal, persistent/pipelined input,
  malformed-input recovery, zero stderr; `build/qa-v3-cycle110-helper-final.{log,json}`.
  Helper SHA-256: `02789d08a8d87ebf6f56e63667ee4bb70551022e028fb64e5d9073402d6d18c7`.
- Repository validation passes in `build/qa-v3-cycle110-repository-final.log`; final documentation
  whitespace/link checks are recorded in `build/qa-v3-cycle110-documentation.log`.
- Independent final store/helper/native/test/documentation review found no remaining actionable
  finding. Earlier review found stale reused-ID admission/cancellation handles and an unbound
  failure-to-uncertainty transition; exact epoch guards and captured native identity resolve both.
  The final schema permits retained legacy omission while runtime refuses every new epochless intent.
- The first sandboxed Xcode attempt could not write package/compiler caches. Authorized Xcode
  execution resolved that environment limit. Its first compile exposed three Int-to-Int64 helper
  count conversions, corrected before passing tests. No test assertions or storage protections
  were weakened.
- Computer-use inventory confirmed desktop availability. A target observation completed after
  native teardown and opened a fresh empty QA window, so it is not additional manual workflow
  evidence. No metadata edits or Settings changes were made; keyboard/menu cleanup closed that app, and
  a process snapshot confirmed no Photo Agent app or UI runner remained.

Exact Xcode invocations are retained at the start of each log. Unit runs use scheme
`Aagedal Photo Agent Tests`, Debug, `platform=macOS`, the shared derived-data path above,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`. Native runs use
`build-for-testing` and `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
120/180-second execution allowances and named workflow selections.

## Remaining and next actions

1. Continue authenticated IPC/guarded helper commits and shared production face, metadata/Develop
   template and transcription executors. Requests still require explicit native review and consent.
2. Extend capacity recovery only with exactly verified linked-terminal removal eligibility and
   preserved operation/recovery authority. Missing history, expiry, admission uncertainty, live work
   and unresolved recovery cannot prove safe retirement. Qualify physical crash/link-loss and
   archive rollback/deletion separately; an archive-local epoch does not establish external
   monotonic authority or protect manually deleted/restored storage.
3. Complete iCloud keyword authority, independent-process preferences/power-loss, broader native
   recovery, signed Whisper integration, real Sony/metadata/server/cloud/hardware, accessibility,
   display/HDR/solar/performance, legal/privacy/protected-CI and exact signed-candidate gates.
   Final user acceptance/publication remain separate; llama.cpp stays 3.1.
