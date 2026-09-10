# 3.0 coordinator state

**State:** IMPLEMENTING — cycle 6 scoped Caption conflict recovery is committed and passes automated checks. Native recovery remains pending after the Mac locked.
**Updated:** 2026-09-10
**Latest implementation commit:** `7a503b3f3eedac35b12c70edaa5ee406e4aee075` (2,523 tests / 282 suites passed; native recovery pending).
**Latest native-validated implementation:** `42ace70` (cycle 5).
**Cycle baseline:** `fab8a0f` on `main`; clean checkout at cycle 6 start.
**Coordinator task:** `01a087bc-ce74-72d2-9c16-829b5a984ff9`
**Automation:** `aagedal-photo-agent-3-0-coordinator` — active, every 10 minutes in this task (saved schedule rechecked).

## Current evidence

[Cycle 6](cycle-06-caption-conflict-recovery-2026-09-10.md) implements scoped conflict review,
verified private export and exact queued-set discard, preserving other photos and newer saved
files. Independent source review passes; focused 138 tests / six suites and integrated 2,523 tests /
282 suites pass, with repository validation. Two intermediate fixture-path failures are recorded
and corrected. Final native recovery remains pending: the exact-build launch was blocked by the
locked Mac. Baseline native reproduction proves the old limitation, not the new recovery path.

[Cycle 5](cycle-05-caption-retry-intent-2026-09-10.md) records independently reviewed immutable
Caption retry intent, guarded write completion/cleanup, and owned scalar/multiline buffer capture.
Final focused validation passes 165 tests / nine suites; full regression passes 2,512 tests /
281 suites, with repository checks. Native partial-mirror retry preserved newer metadata without
duplicate history. Native direct Write & Next from focused Headline and Description now writes
the actual typed values, advances successfully and preserves the other photo and original pixels.
Normal quit/relaunch retained the final values and exact artifact hashes. Earlier intermediate
native failures and their corrections are explicitly recorded; no final readiness is claimed.

The [cycle 4 record](cycle-04-caption-restore-ownership-2026-09-10.md) records native defects and
corrections for explicit Restore, history buttons, pending markers and automatic lifecycle writes,
plus owned JSON preservation and Duplicate naming/opaque metadata. Final focused checks pass
129 tests / eight suites; full regression passes 2,479 tests / 280 suites, with repository checks.
Native repeated Restore, history points, relaunch and deactivation
preserve pending state and source bytes. After temporary host lock resolved, final Duplicate and
ownership relaunch passed with all original and reopened fixture hashes preserved.

The [cycle 3 record](cycle-03-memo-trash-2026-09-10.md) identifies the implementation, independent
review, exact automated results, native interactions, artifact hashes and limitations.
The [Caption follow-up](cycle-03-caption-baseline-2026-09-10.md) records cycle 3
source, 111 focused tests, 2,449 full tests, native unchanged-draft byte checks and real edits.
The [gate inventory](gate-inventory.md) preserves all 61 unchecked baseline criteria with
classifications and concrete next actions. Current authoritative plans contain 60 unchecked criteria
(9 audit, 23 investigation, 22 journalistic, 6 solar). Playback's narrow implementation criterion is checked;
broad lifecycle, real-sample and accessibility gates remain open. The audit remains 66/75 and
investigation delivery 119/142. No final release candidate was offered for acceptance.

Cycles 1–2 implemented Caption WAV playback, independent Duplicate, companion-aware Move/Reject,
thumbnail I/O and selection accessibility fixes, and accessible toolbar/context dialogs.
Cycle 3 adds a single recoverable Trash folder per associated photo, shared WAV/XMP preservation,
JSON ownership checks, rollback/uncertain-outcome details and complete native error details.
Move/Reject now preserve sibling XMP and legacy JSON instead of consuming or adopting them.
Untouched pending Caption drafts no longer rewrite JSON/XMP; real edits retain the saved original
snapshot. A new failed-save regression exposed a synchronous retry deadlock, resolved by removing
a hidden MainActor dependency from metadata lock-key calculation and isolating the async bridge.
The historical unrelated project ordering diff was committed separately as `fee5b0d` before
cycle 3. No unrelated dirty source was present when cycle 4 began.

## Ordered next actions

1. Finish native verification of [scoped Caption conflict recovery](caption-conflict-recovery-design.md)
   on committed `7a503b3`: actual A conflict, cancel/export/tamper rejection, explicit scoped discard,
   actual B/C persistence, normal Close/Quit and relaunch. The implementation and automated tests
   pass; native launch was blocked by the locked Mac. Recheck availability without bypass.
   Then implement the [field-write and Metadata Review design](field-write-completion-design.md)
   for the [adjacent writer paths](cycle-05-caption-retry-intent-2026-09-10.md):
   Browser rating/label/rotation and Metadata Review, Face person-name writes, batch XMP completion
   and non-displayed variable writes. Preserve unrelated pending drafts and report per-photo
   destination failures before clearing status. Cycle 5's new service alone does not fix these callers.
2. Complete remaining Sony companion archive and source reassociation using the source-backed
   [archive design](voice-memo-archive-design.md). Ingest, rename, Duplicate, Move, Reject and
   memo Trash now have implementation. Preserve explicit ownership through rendering/signing/
   cleanup; schema-1 filename hints alone cannot establish historical reassociation identity.
3. Implement cancellable local transcription with explicit language/model/offline state,
   review-before-apply and transcript provenance, following the [SDK-backed design](voice-memo-transcription-design.md).
   Integrate reviewed transcript variables and visible Deadline WAV delivery policy/receipt.
4. Continue actual UI checks across required workspaces and failure/recovery cases, plus remaining
   storage/executor auditing. Cycle 3 observed native Trash, shared survivor playback, missing-memo
   Details, Finder Put Back, exact bundle recovery and restored Caption persistence. Broaden to
   real Sony, long error scrolling, face-group Trash, Bridge/Photo Mechanic, disposable transports,
   accessibility/IME/display, solar/reports and measured performance. Narrow evidence is not a full gate.
5. Establish missing hardware/model-lifecycle/privacy/remote-CI evidence. Qualified legal review
   and protected remote branch enforcement remain external prerequisites. Complete independent
   work before an actionable blocker handoff; do not silently move mandatory gates to acceptance.
6. Once unconditional gates pass, obtain independent readiness review, build/launch the exact
   candidate, finalize and visually verify the [HTML checklist](manual-testing-checklist.html),
   then follow [the coordinator protocol](coordinator.md) before notifying for acceptance.

## Open gate groups

| Gate | Current disposition | Required evidence |
| --- | --- | --- |
| Required features | Open | Archive/reassociation, transcription, reviewed variables and delivery; inventory dispositions |
| Storage, cancellation and integrity | Open | Scoped FIFO conflict recovery, remaining writer completion/ownership, real-volume drills |
| Automated regression and package | Cycle 6 regression/repository checks passed | Integrated checks, packaging and exact-candidate launch remain |
| Computer-use workflows | Narrow native lifecycle checks passed | Remaining required workspaces, failures/recovery and authentic fixtures |
| Accessibility/layout/display | Open | Full keyboard/VoiceOver, IME, contrast/motion, window/display evidence |
| Performance/supported hardware | Open | Target tiers/budgets and measured workloads |
| External interoperability/transport | Open | Actual Bridge/Photo Mechanic and disposable FTP/FTPS/SFTP evidence |
| Model distribution/offline lifecycle | Open | Required signed artifact/server/install/offline/update/rollback evidence |
| Privacy/legal/remote CI | External dependency | Qualified review and authorized remote configuration evidence |
| Final user acceptance | Not started | Candidate-specific HTML results after readiness decision |
| Signing/notarization/distribution | After applicable gates | Separate authorization and release-plan evidence |

## Blocker tracking

Cycle 6's final recovery build could not launch through CUA because the Mac was locked. Automated
checks, independent review and local commit work completed. Recovery native evidence remains
mandatory, and the prepared final fixture is untouched. Recheck access next; no bypass is allowed.
Other implementation work remains available, so this is not a total-progress blocker or a reason
to notify the user yet.

XCTest failed to establish its daemon control session twice before executing any tests.
[Diagnostics](cycle-03-test-launch-diagnostics.md) distinguish this from product failures.
After host access resumed, the same source passed 119 focused tests / five suites and all
2,445 tests / 278 suites. No shared daemon reset, unrelated process interruption or product
workaround was used. No user action is pending for that historical failure.
The later Caption regression executed and exposed a product deadlock, separately diagnosed and
fixed; cycle 3 integrated results are 111 focused / 2,449 full tests passing. Do not confuse that
resolved defect with the earlier prelaunch environment issue.

Cycle 4 CUA temporarily reported the Mac locked. Independent full tests and source commit work
continued; access resumed on recheck at 10:47 UTC. Final Duplicate/ownership relaunch then passed,
all fixture hashes were verified, and native inventory confirmed the QA app stopped. No unlock
bypass was used and no user action remains for that temporary limitation.

Historically, computer access paused for hours during a Finder call, then resumed. Recheck host/UI availability
on each run. Final stale menu references were resolved by resetting only the CUA JavaScript
session. The final QA process was quit and native inventory confirmed it stopped. Finder was
returned to its original window. Bridge is available, but presence is not interoperability proof.

Browser visual QA of the checklist remains pending: URL policy rejected its local file URL
at setup. Do not bypass with another route. Static checks passed for 30 complete cases, unique
IDs, local source links and JavaScript syntax. It remains unassigned to a candidate and all
human results are unrun.

Consecutive runs with no possible progress: 0. Substantive implementation and verification
progress occurred. Automation remains active; no readiness notification is warranted.

## Latest handoff

Disposable fixtures remain under `build/qa-voice-memo-cycle1/`, `cycle2/` and `cycle3/` using their
full `qa-voice-memo-cycleN` directory names. Cycle 3 includes two restored whole Trash folders;
keep their hidden records/metadata with their images and WAVs. See the cycle record for exact
names and intentional changes. No private photo metadata, remote configuration, production
transfers or publication was changed. Source code is committed; documentation accompanies it.
`build/qa-caption-baseline-cycle3/` contains the two pending-draft cases, original and post-edit
hash manifests; only `unmirrored.png` received an intentional Headline edit and new XMP sidecar.
Cycle 3's final QA process was quit normally. Other project processes and files were left untouched.
Cycle 4 fixture/evidence folders are documented in its dated report. Both final Restore and
ownership sessions were quit after relaunch hash verification; all QA processes are stopped.
Recheck native availability and checkout/task ownership next cycle.

Cycle 5 source is committed as `42ace70`; its dated report contains final v5 binary identity,
full/focused results and native hashes. Disposable baseline and final retry fixtures remain in
`build/qa-caption-retry-cycle5-baseline/` and `build/qa-caption-retry-cycle5-final/`. The final
first photo intentionally contains Headline F, Description V5 and independent credit C in embedded
and companion XMP; its JSON is absent after successful explicit Write cleanup. The next photo is
untouched. Relaunch hash verification passed and native inventory confirmed the QA app stopped.
Begin next cycle with the scoped conflict-recovery design, preserving all unrelated queued work;
then address the inventoried adjacent writers. No broad gate or final user acceptance is closed.

Cycle 6 recovery source is committed as `7a503b3` with focused/full/repository checks passing;
its exact binary identity and failed native-launch evidence are in the dated report. Baseline
native fixture `build/qa-caption-conflict-cycle6/` was intentionally ended using Quit Without
Saving after proving the old permanent conflict; inventory confirmed that baseline app stopped.
Fresh `build/qa-caption-conflict-cycle6-final/` is untouched and ready for final recovery testing.
Do not report actual B/C resumed writes or recovery Close/Quit as passed until native testing runs.

After independent commit/document work, a second CUA launch recheck still reported the Mac locked.
The [field-write continuation design](field-write-completion-design.md) captures the independent
source audit, concrete API/lock boundaries and tests for Browser/Face/Metadata Review; no new
implementation is claimed for those paths. Useful source work remains, so the no-progress count
stays zero and automation remains active.
