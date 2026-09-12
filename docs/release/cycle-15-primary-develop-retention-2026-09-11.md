# Cycle 15 — retained Primary Develop writes

Status: retention implementation `ae99369` and notice follow-up `be970f0` pass independent review, automated checks and their native regressions. Wider release gates remain open.
Baseline: `e72ceef` (documentation), implementation `a777dd7`.

## Confirmed defect and intended behavior

Cycle 14 confirmed that dismissing an actual failed Primary Develop save and using
normal Quit lost the unsaved intent. The named-version flush returned success for
Primary, and failure presentation was the only remaining owner.

This cycle retains immutable Primary requests in the metadata owner, independently
of view, selection, alert and waiter lifetime. A shared lifecycle barrier captures
dirty controls before awaiting accepted writes, and refuses exit while work remains.
Native recovery is reachable outside that failure barrier. Retry uses original
source, JSON and XMP evidence. Partial or uncertain physical writes require complete
verified recovery export and exact-request discard rather than blind replay.

## Ownership and verification plan

- Core owner: request/service, engine verification capability, load-time source
  evidence, retained FIFO, retry and scoped recovery, with focused tests.
- Lifecycle owner: shared retained-owner registry, dirty-editor capture and
  persistence-session lifetime tests; independent integration review.
- Workspace owner: Primary commit routing, transient crop capture, version and
  navigation barriers, recovery buffer coordination.
- Coordinator: app termination/global flush, recovery host and toolbar, integration,
  serial builds, native disposable fixtures, documentation and local commits.

Required verification: focused retention/recovery tests, independent review,
integrated suite and repository checks; actual masked save/failure, dismissed alert
followed by Quit, recovery cancel/export/tamper/scoped discard, preservation of other
work, and normal relaunch. Record exact binary identity and fixture hashes before
claiming native results. The 60 open authoritative criteria remain open.

## Execution interruption and resumed review — 2026-09-12

All three implementation agents reported account usage exhaustion during integration
on September 11. Scheduled wakeups accumulated without verified implementation or
test progress; they are not successful cycles. On September 12 the usage tool
reported capacity available and work resumed from the unchanged dirty checkout.
No reset credit was redeemed and no purchase was made.

Outstanding source-review findings at resumption: rapid successive edits may capture
a stale predecessor baseline; generic writes must not bypass retained Primary work;
embedded technical writes need verification; global flush must reject a replaced
workspace registration after waiting. All remain unverified until fixed and tested.
Disposable cycle-15 masked PNG fixtures were prepared under
`build/qa-primary-develop-cycle15`; no cycle-15 native interaction has run.

## Integration checks in progress

First app build (build-v1) could not resolve package manifests because the sandbox
refused Swift/Xcode cache writes outside the checkout. Retried the same authorized
build through sandbox escalation (build-v2); this is not a product test failure.
Project plist and whitespace checks pass. The expanded HTML checklist has 35 unique
complete cases and passes JavaScript syntax checking; actual HTML interaction and
all cycle-15 app tests remain unverified at this checkpoint.

Independent review corrected global stale-workspace handoff, recovery freeze after
await, absent-editor discard and reload error ownership. Queued dual-write Undo
comparison was additionally flagged and remains to be corrected after build-v2.

Build-v2 reached app compilation but failed on SwiftUI type-check time at
`EditWorkspaceView.swift:731`. The view owner split the large modifier expression
into typed subviews, preserving modifier order; rebuild remains required. Core
review also identified a newer-editor overwrite during async recovery reload and
older-request deduplication during A→B→A rapid edits. These are being covered by
the core correction and regression tests, not waived as timing-only cases.

Focused-v1 compiles the refactored application, but test compilation stopped at
`PrimaryDevelopWriteServiceTests.swift:276`: a blocking `wait` is unavailable from
an async context. No test assertions ran. The deterministic test gate is being
corrected. Repository validation v1 passes; its log is in the cycle-15 fixture root.

Focused-v2 ran 101 tests across five suites in 4.022 seconds. All new retained-write
and lifecycle tests passed; the single failure was the existing architecture
source assertion still requiring the generic metadata caller. Updated that assertion
to require `commitPrimaryDevelopEdits`; focused-v3 is the verification run. No product
assertion was removed or suppressed.

Focused-v3 passes 101 tests / five suites in 4.843 seconds. The full-v1 run was
intentionally interrupted (exit 75, TEST INTERRUPTED) after independent review
identified missing export-destination protection for watermark files referenced
only by successful predecessor requests. The exported ancestry must also define
the protected paths. This narrow correction and its regression precede the final
integrated run. Photo Agent app inventory confirms all its entries stopped after
the interruption; unrelated applications remain untouched.

Focused-v4 passes 103 tests / five suites in 5.989 seconds, including ancestor
export protection and same-value XMP-to-dual saves. Independent review passes the
current UI's XMP and dual routes. File-only orientation chaining is a latent API
limitation outside those UI routes; no file-only support is claimed for this new
retained path. Repository validation v2 passes.

Full-v2 ran 2,687 tests / 297 suites in 110.287 seconds with one failure in the
unchanged Known People asynchronous deletion gate (success variant, gate not entered
at line 753). All Primary tests passed. A focused Known People rerun and independent
diagnosis are in progress; the failure is not waived or labeled a product pass.

The unchanged Known People rerun passes 64 tests in 14.216 seconds. Independent
review confirms that gate entry is monotonic and subsequent deletion assertions
passed: the failed wait expired before the worker entered. Log wall-time gaps
and differing reported elapsed times suggest suspension or clock accounting, but
do not prove the cause. No timeout, assertion or Known People implementation was
changed. Full-v3 is running on unchanged source to check reproducibility.

## Verified retention checkpoint — `ae99369`

Full-v3 passes 2,687 tests / 297 suites in 102.945s. The source was committed as
`ae99369c71ad8e076a3d40c2d7a74c0bd942b635`. Native testing used Debug 3.0.0 (738),
macOS 27 arm64; exact app path and all executable hashes are in
`build/qa-primary-develop-cycle15/tested-binary-identity.json`. The debug dylib hash is
`3042cdaff364c6f17449ac0c4e10115647aceebb4e26b2193e5248161e76c34f`.

Observed native sequence and evidence (all paths below are under that fixture root):

1. Opened `photos`, selected A and reset exposure from0.25 to0. Masks, caption and
   original PNG bytes survived (`after-reset.json`). Cmd-Z then Exit Develop wrote
   exposure+0.25 to XMP (`after-undo-exit.json`), closing the earlier Undo durability gap.
2. Reopened Develop and externally changed only the disposable A XMP to+1.75. Reset
   failed visibly with the exact XMP conflict. Dismissed its alert and pressed Cmd-Q:
   the app displayed Develop Save Failed with only Keep App Open. Exit Develop and
   photo-B selection also refused; A remained selected. All artifacts matched
   `external-conflict-baseline.json` (`after-refused-exits.json`).
3. Explicit Retry still refused the original conflict. Review opened outside the
   failed barrier. Cancel retained the request. Save-panel Cancel kept Discard disabled.
4. Exported `primary-recovery.json` (mode0600), appended a newline externally, and
   verified Discard refused the changed bytes. Exported `primary-recovery-verified.json`
   and discarded only its one A request. Export contains the captured+0.25 XMP bytes,
   intended reset, full metadata/history/source evidence. All saved photo artifacts
   remained exactly unchanged (`after-discard.json`); Undo was disabled afterward.
5. A fresh reset succeeded from the reloaded+1.75 baseline. B explicit Develop Reset
   removed its embedded and XMP CRS/mask while preserving both pixel payloads, captions
   and A's mask (`completed-artifacts.json`). Normal Quit succeeded. Relaunch/open both
   photos showed A at0 with its ellipse and B at0 without it. Every artifact matched
   exactly (`relaunch-artifacts.json`). All Photo Agent entries were then stopped.

No preferences changed or user photos were used. Available recovery actions and
the Quit refusal were visually inspected; the detailed accessibility states are in
this task's tool record. Native simultaneous in-flight requests/held recovery reads
were not simulated through the UI; deterministic automated tests cover those races.
Other-photo artifact preservation was checked natively; retained-other-photo queue
ownership has automated evidence rather than a claim of native concurrent queues.

Native testing found one presentation defect: after successful recovery, the earlier
Primary failure text remained in the named-version notice, including after a new
successful save. The view-only follow-up separates Primary and named notice ownership
and clears only resolved Primary attention. It has independent review; its automated
and native retest remain to be recorded.


## Final notice regression — `be970f0`, 2026-09-12

The notice correction is committed as `be970f06da96f330500f8d4a4cdec64a07165086`.
Independent review passes. `notice-focused.log` passes 51 tests / four suites in
4.797s; `notice-full.log` passes 2,687 tests / 297 suites in 92.351s;
`notice-repository.log` passes. These logs are under the cycle15 fixture root above.

A fresh synthetic fixture root, `build/qa-primary-develop-cycle15-notice`, records
`fixture-origin.json` and `tested-binary-identity.json`. Debug 3.0.0 (738), macOS 27
arm64, debug dylib SHA-256 is
`b9b5c102da553e38a15bd140aa2521054f26db919779b9a6ec4ca18cb48cbe4c`.
Source was clean at the tested commit; only handoff documentation was dirty.

After loading A at exposure +0.25, an external disposable XMP change to +1.75 caused
Reset exposure to fail visibly. Dismissing the alert and trying Exit Develop kept
the editor open with Primary retained-work attention. Recovery export was saved,
then deliberately changed by appending a newline. Discard refused the changed export
and disabled its action; Cancel returned to the editor with the warning still visible.
A fresh verified export enabled scoped discard. After discard, the warning and
Review/Retry controls disappeared and Undo was disabled. All photo artifacts exactly
matched the external baseline (`external-baseline.json` == `after-discard.json`).
A fresh exposure reset saved successfully with no stale warning; the screenshot was
visually inspected. Exit Develop and normal Quit succeeded, and all four installed
Photo Agent entries reported stopped. `completed-artifacts.json` records final disk state.

Recovery files are `notice-recovery-original.json` (39,304 original bytes), the
intentionally tampered `notice-recovery.json`, and `notice-recovery-verified.json`.
They are outside the photo directory. No preferences changed or user photos were used.
The final view-only regression did not repeat the earlier checkpoint's relaunch,
dual Reset or Quit-refusal sequence. Named-version failure presentation has independent
source review, not a new native failure simulation. Broader remaining native cases
and all 60 unchecked plan criteria remain open; no candidate readiness is claimed.


Final independent evidence/documentation audit passes: commit/binary identity and
reported log counts match, exact discard artifact comparison passes, and native
coverage boundaries are explicit. Static checklist validation confirms 35 unique
complete cases (20 agent, six final user, nine external/hardware), resolving source
links and valid JavaScript syntax. Interactive checklist validation remains open.
Only A JSON/XMP changed after the final fresh save; both PNG sources stayed exact.
