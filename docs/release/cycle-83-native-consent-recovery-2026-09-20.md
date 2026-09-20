# Cycle 83 — native exact-plan consent and stopped-owner recovery

Baseline `55c9eb7`, initially clean. Two implementation agents owned disjoint consent and
operation-registry changes; the coordinator integrated native smoke coverage and documentation.
An independent agent reviewed the changes. Implementation is committed as `6f9fd01`. Readiness remains IMPLEMENTING.

## Implemented behavior

- Settings → Automation → Proofreading Plan Review now offers **Approve Reviewed Plan**
  after the exact before/proposed values and preservation warnings. Approval rechecks the
  immutable source/sidecar/authorization binding. A changed source refuses consent and clears
  the stale review. Approval does not write metadata or expose a helper commit endpoint.
- Local approval receipts remain internal to the review session. Revoke Approval, Clear Review,
  changed plan IDs, navigation, expiry and model destruction remove consent. Cancelled or
  superseded asynchronous completions cannot publish approval; any returned receipt is revoked.
  Presentation-only previews and reviews from a different service session cannot grant consent.
- The durable operation registry can reconcile one explicitly identified stopped owner.
  Its unresolved records become completed with the distinct recoveryRequired outcome; IDs,
  creation times and cancellation evidence remain intact. Other owners and terminal records
  remain untouched. Repeated reconciliation preserves timestamps. The caller must establish
  that the owner has stopped; neither restart nor elapsed time performs automatic recovery.
  Batch clock validation and the existing locked atomic transaction prevent partial updates
  on clock rollback, storage contention or capacity refusal.

## Validation

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Xcode 27.0 (27A266a). Disposable generated JPEGs and isolated
in-memory authority/plan stores exercise the real planner and native consent service.
No user photo or automation preference is changed by these tests.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'`, Debug,
`-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2`. Unit scheme:
`Aagedal Photo Agent Tests`; focused selection: MCPIPTCPatchApprovalStoreTests,
MCPIPTCPatchPlanStoreTests, AutomationOperationRegistryTests and AutomationPatchReviewTests.
Native scheme: `Aagedal Photo Agent UI Smoke Tests`; selected CoreWorkflowSmokeTests methods:
testAutomationPatchApprovalRevokesAndRefusesChangedPhoto,
testAutomationPatchReviewDisplaysExactPlanAndRefusesChangedPhoto and
testAutomationPatchReviewRefusesInvalidPlanWithoutChangingPhotos.
Repository command: `scripts/ci/validate_repository.sh`.

The initial focused run passed before the last lifecycle/test additions. The subsequent build
caught nonisolated model destruction accessing MainActor state; `isolated deinit`, already
used elsewhere in the app, fixes that compile error. Neither preliminary run is final-source
validation.

Final focused validation passes **37 tests / four suites**, zero failures, in **1.440 seconds**
(`build/qa-v3-cycle83-focused-fixed.{log,xcresult}`). Native testing passes **three workflows**,
zero failures or skips, in **92.665 seconds** (`build/qa-v3-cycle83-native.{log,xcresult}`):
explicit approval/revocation/Clear/navigation/changed-source refusal (42.645 seconds), existing
Unicode/set/clear/navigation/stale-source inspection (30.241 seconds), and invalid-ID/clear
feedback (19.778 seconds). The native assertions verify unchanged JPEG bytes and no sidecars.
The current development app is version 3.0.0, build 739, at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
It is not a distribution candidate offered for final acceptance.

The actual helper probe passes persistent STDIN, pipelined requests, malformed-input recovery,
provider discovery/argument refusal and clean EOF with zero stderr bytes. It discovers all
12 existing tools; it does not exercise every tool. Helper SHA-256 remains
`7dccfdf258287d2dc9e1acbbd79132bc6f113800e7aad635a521a8702bfc67af`;
evidence is `build/qa-v3-cycle83-helper.{json,log}`. Checklist A21 includes explicit local consent;
its embedded JSON validates as 36 cases with unique IDs, without marking unrun cases passed.

Independent review found no remaining actionable source defects. Native result summaries retain
QoS and main-thread runtime warnings, and the driver log contains display-manager diagnostics.
Assertions pass; these observations do not close the broader responsiveness audit. Reading the
result summary required xcresulttool report-cache access, just as builds require compiler-cache
and test-service access.

The complete integrated regression passes **3,195 tests / 336 suites**, zero failures, in
**136.642 seconds** (`build/qa-v3-cycle83-full.{log,xcresult}`). This run uses the implementation
committed as `6f9fd01`; documentation was finalized afterward. Final repository validation and
staged whitespace checks pass (`build/qa-v3-cycle83-repository-final.log`). No assertions were
weakened and no broad release gate was newly closed.

## Remaining release work

Guarded production IPTC commits, semantic read-back and physical preservation, production
operation admission/status/cancellation, executor liveness, recovery execution and per-photo
outcomes remain open. These primitives do not complete any full Phase 5A criterion.
Deterministic testing of approval completing after Clear Review and direct expiry UI coverage
remain narrower validation gaps; current tests cover queued cancellation and stale source refusal.

Curated signed Whisper model delivery, the expanded FFmpeg artifact and notices/size packaging,
real-model accuracy/offline/failure acceptance, additional audio formats and supported MCP-client
workflows remain. Broader gates include authentic Sony/RAW/C2PA and external metadata
interoperability, real servers, iCloud/multi-Mac, interruption/recovery, accessibility,
display/map/report and performance evidence, qualified legal/privacy review, protected remote CI,
exact-candidate packaging/review and final user acceptance. No release package is published.
