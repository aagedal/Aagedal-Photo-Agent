# Cycle 112 — recovery-qualified native review request retirement

Baseline: `c42dcff`, initially clean. Implementation commit: `a09cb30`. Final application/test
bytes were verified before committing those identical bytes. State remains **IMPLEMENTING**;
no whole 3.0 gate closes.
Two bounded implementation agents owned request storage/tests and native workflow/copy respectively.
An independent agent reviewed the integrated source and tests; the parent owned recovery-store API,
native service wiring, service regressions, integration, builds, documentation and commits.
Chat inventory found no other active chat editing this checkout; desktop inventory found no running
Photo Agent app or UI runner before testing. Only owned changes are staged.

## Implemented and decision

- The existing confirmed **Remove finished review requests** action also admits linked XMP
  operations with `recoveryRequired` or `partialUncertain` outcomes only when their separate durable
  recovery resolution matches the exact retained completed restoration or unchanged-staging receipt.
  Operation ID, request plan, disposition and SHA-256 must match. Operation kind and admission timing
  still match; both operation update and recovery resolution must be at least as recent as the request.
  Later request cancellation cannot become eligible through an unrelated operation timestamp update.
- The recovery store exposes a generic synchronous read-only locked disposition callback carrying
  operation and plan identity. Maintenance holds recovery, operation and request locks in that order,
  matching existing recovery-to-history reconciliation. Snapshot and cleanup reload all evidence;
  explicit cleanup checks the captured epoch before removal, rotates it and disables legacy creation.
  Original operation outcomes and operation/recovery archive bytes remain unchanged. Cleanup grants
  no execution consent, and restoration or unchanged staging never establishes successful publication.
- A digest in operation history alone is insufficient. Missing, replaced, unresolved, publication-only,
  incomplete, mismatched, corrupt, insecure or contended recovery evidence cannot qualify uncertainty.
  The single retained journal qualifies only its matching request; historical digests after journal
  replacement do not qualify. Uncertain drafts, active/unlinked admissions and unavailable operation
  history stay retained. This conservatively trades some capacity for verifiable retained evidence.
- Native service inspection and confirmation use their captured recovery route. Unavailable operation
  or recovery history leaves finished eligibility unavailable while preserving separate cancelled-only
  cleanup. Native copy, helper discovery copy, README, feature help, limitations and the authoritative
  journalistic plan describe the exact completed-recovery boundary.
- Native testing exposed a confirmed cleanup that silently did nothing. A deterministic held-read
  regression reproduced the same refusal for both cleanup actions: periodic read-only evidence refresh
  disabled their confirmation guards. Confirmed actions now accept the captured eligible epoch even
  during a read-only refresh, cancel and invalidate that refresh, then perform the existing locked
  service revalidation. Button eligibility still prevents opening cleanup during refresh; active
  execution/capacity work and stale confirmation remain refused. Late read results cannot resurrect
  removed requests. The smoke helper explicitly waits for each confirmation sheet to dismiss.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Tests use generated disposable photos and isolated authority/request/operation/recovery stores;
native teardown terminates the test app and removes fixtures/preferences. No user photos, model
installations, remote writes or Release candidate are used.

- Final focused suite: **132 tests / six suites**, zero failures, 15.425 seconds,
  `build/qa-v3-cycle112-focused-final.{log,xcresult}`. Covers resolved/unchanged receipts for both
  uncertain outcomes, all identity/timing mismatch cases, unresolved publication/incomplete
  restoration, missing/replaced/corrupt/insecure/contended journals, preserved archives, capacity,
  epoch/legacy replay, isolated recovery routes, corruption fallback, held read refresh and late
  evidence-result rejection, consent clearing and stale confirmations.
- Repository validation passes in `build/qa-v3-cycle112-repository-final.log`.
- Actual bundled helper probe passes **22 tools**, persistent/pipelined input, malformed-input
  recovery, strict argument refusal and zero stderr;
  `build/qa-v3-cycle112-helper-final.{log,json}`. SHA-256:
  `da60924c6863fb4e97027e086a56aaeb5025580c2ce6d95f0a5b0925fe1c27b2`.
- Independent source/test review found no remaining actionable issue. Review corrected a restored
  missing-journal fixture to restore private `0600` permissions and removed stale plan language.
- Initial native run passed existing finished/cancelled cleanup but failed the new recovery workflow
  after confirmation with unchanged request capacity and no completion message;
  `build/qa-v3-cycle112-ui.{log,xcresult}`. Full selected-test attachments and the activity tree are
  retained in `build/qa-v3-cycle112-ui-detail/` and `build/qa-v3-cycle112-ui-activities.json`.
  The held-read regression reproduced both cleanup refusals before the fix in
  `build/qa-v3-cycle112-confirmation-before-fix-suite.{log,xcresult}` (46 tests, two parameter-case
  issues). An earlier function-only selector ran zero tests and is not validation evidence.
  The final focused run passes that regression; execution, authority and epoch guards and
  assertions remain intact.
- Pre-fix integrated suite passed **3,586 tests / 358 suites**, zero failures, 161.801 seconds,
  `build/qa-v3-cycle112-full.{log,xcresult}`. It precedes the confirmation-race fix; final integrated
  and native results follow separately.
- Initial sandboxed Xcode invocation refused compiler/package cache writes. Authorized execution
  resolved the environment limit; no permissions, app settings or authority boundaries were weakened.

- Final native workflows: **three tests**, zero failures, 176.305 seconds,
  `build/qa-v3-cycle112-ui-final.{log,xcresult}`; final native build passes in
  `build/qa-v3-cycle112-ui-build-final.log`. The new workflow executes a linked XMP request with
  interrupted app-history receipt, verifies zero finished eligibility and unchanged artifacts before
  recovery, explicitly restores originals, checks exact request/operation/plan/digest binding and
  the separate restored marker without changing `recoveryRequired`, cancels cleanup with byte-exact
  preservation, then confirms removal of only the recovered request with epoch rotation and unchanged
  other request/operation/recovery/photo/carrier evidence. Relaunch preserves those exact archives
  and the restored absent carriers. Existing finished-XMP and cancelled-only cleanup/relaunch
  workflows also pass after the confirmed-refresh fix.

- Final serial integrated suite: **3,587 tests / 358 suites**, zero failures, 152.647 seconds,
  `build/qa-v3-cycle112-full-final.{log,xcresult}`. Twelve existing Thread Performance Checker
  diagnostics and host `MDB_MAP_FULL` messages remain observations; the performance gate stays open.
- Final desktop inventory confirms no Photo Agent app or UI runner remains. Documentation whitespace
  and local-link checks are recorded in `build/qa-v3-cycle112-documentation.log`. No Release candidate
  was built and no whole implementation, performance or release-readiness gate is closed.

Exact Xcode invocations are retained at the start of each log. Unit runs use scheme
`Aagedal Photo Agent Tests`, Debug, `platform=macOS`, the shared derived-data path above,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`. Native runs use
`build-for-testing` and `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
120/180-second execution allowances and named workflow selections. Native XCTest results are
automated interaction evidence, not manual user acceptance.

## Remaining and next actions

1. Continue authenticated IPC/guarded helper commits and the shared production face, metadata/Develop
   template and transcription executors. Requests still require explicit native review and consent.
2. Qualify physical crash/link-loss, archive deletion/rollback and independent-process preference/
   power-loss behavior. Archive-local epochs provide no external monotonic authority against manually
   restored/removed storage. Supporting retired recovery requests after journal replacement would need
   separately retained exact receipts; a digest alone is intentionally insufficient.
3. Complete iCloud keyword authority, arbitrary export coverage, broader native recovery, signed
   Whisper integration, real Sony/metadata/server/cloud/hardware, accessibility, display/HDR/solar,
   performance, legal/privacy/protected-CI and exact signed-candidate gates. Final user acceptance
   and publication remain separate; llama.cpp stays 3.1.
