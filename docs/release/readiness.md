# 3.0 coordinator state

**State:** IMPLEMENTING — durable rotation passes native history/relaunch/dual-apply verification. Metadata Review retained replay/recovery is being integrated; remaining feature and release gates stay open.
**Updated:** 2026-09-11
**Latest implementation commit:** `b5840e4304450dce9371b5c2329e230635adf351` (2,569 tests / 285 suites and repository checks passed).
**Latest native evidence:** `b5840e4` history-only rotation, full-screen, relaunch, Write All refusal and same-target dual apply PASS in cycle 10; preferences restored and QA app stopped.
**Cycle baseline:** `5afb5f3` on `main`; cycle 10 was interrupted and resumed with its owned work preserved.
**Coordinator task:** `01a087bc-ce74-72d2-9c16-829b5a984ff9`
**Automation:** `aagedal-photo-agent-3-0-coordinator` — active, every 10 minutes in this task (saved schedule rechecked).

## Current evidence

[Cycle 10 native continuation](cycle-10-rotation-native-2026-09-11.md) resolves the rotation setup
blocker on unchanged `b5840e4`. History-only angles 6/8 survive full-screen and relaunch; Write All
reports the full refusal and preserves all artifacts. Explicit same-target dual apply writes EXIF
and both XMP conventions, removes only rotation intent, preserves G/null snapshot/history/pixels,
and survives reopening. Original Professional/Custom preferences and General page are restored;
native inventory confirms the QA app stopped. Metadata Review code is in progress in the shared
checkout; it has not yet been built or validated. Other listed tasks use separate repositories.


[Cycle 9](cycle-09-durable-rotation-2026-09-11.md) implements ordered Browser rotation, a durable
technical JSON draft, per-destination retry baselines, same-target Write Pending Rotation, and
thumbnail/full-screen pending orientation. Caption and null snapshots survive; complete-record
writes/export/FTP admission require pending rotation to be applied first. Full checks pass 2,569
tests / 285 suites and independent review passes. Two new fixture construction defects were
corrected and documented; no product assertion was suppressed. The exact final build launched
and opened the disposable folder, then the Mac locked on the Custom preset click. **Native
rotation remains unrun and preference cleanup is pending:** inspect Settings before assuming the
click applied; restore Professional and Custom Standard Images = Write to Image File after testing.
All four original fixture artifacts remain byte-identical. The QA app was not confirmed stopped.



[Cycle 8](cycle-08-explicit-label-clear-2026-09-11.md) implements standard empty XMP Label
presence through merge, JSON/XMP, Browser reload and export/FTP field mapping. An absent label
still inherits. Focused v3 passes 68 tests / five suites, integrated checks pass 2,554 tests /
285 suites, and repository validation plus independent source review pass. Native XMP-only clears
preserve embedded PNG bytes, pending captions and null snapshots; restored preferences and relaunch
retain None/None/Blue for two clear cases and an absent-label control. The final full-suite build
was separately launched and preserves all eight fixture artifact states. Normal Quit and native
inventory confirm every QA app entry stopped. Prior Face34a now passes actual partial failure,
full error details, repair/retry, destination-only names and relaunch with exact hashes.

[Cycle 7](cycle-07-field-write-completion-2026-09-10.md) closes the narrow native recovery gate
on unchanged `7a503b3`: cancel review/export, export tamper rejection, exact A discard, actual B/C
persistence, normal Close/Quit and relaunch all pass. Newer A bytes and all source PNGs are preserved;
artifact hashes remain identical after relaunch. Native inventory confirms the QA app stopped.
Source `34a7313` preserves unrelated pending drafts, nil original snapshots, per-destination names,
ordered intents and actual partial-write receipts. Focused v7 passes 24 tests / two suites after
native Face corrections; integrated v2 passes 2,547 tests / 284 suites plus repository validation.
Earlier focused v6 passes 117 tests / six suites. Native Browser rating/label, clears, failure details,
pending-caption/nil-snapshot preservation and relaunch pass on the recorded pre-Face-correction
binary. Native Face exposed a directory-URL trailing-slash mismatch and missing visible errors;
both are corrected and independently reviewed. The final cycle-7 native launch was blocked by a locked Mac; access resumed in cycle 8 and
actual Face partial failure, retry and relaunch now pass on unchanged `34a7313`.

[Cycle 6](cycle-06-caption-conflict-recovery-2026-09-10.md) implements scoped conflict review,
verified private export and exact queued-set discard, preserving other photos and newer saved
files. Independent source review passes; focused 138 tests / six suites and integrated 2,523 tests /
282 suites pass, with repository validation. Two intermediate fixture-path failures are recorded
and corrected. The cycle-6 native launch was blocked by the locked Mac; access resumed and actual recovery
passed in cycle 7. Its separate record distinguishes baseline failure from corrected behavior.

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

1. Finish, review and validate the in-progress Metadata Review migration in the [field-write design](field-write-completion-design.md):
   Metadata Review retained replay/recovery, then batch XMP completion and non-displayed variable
   writes still have whole-record acknowledgement or untracked replay gaps. Rotation implementation
   now passes tests and native history-only/dual-apply/relaunch; broader failure/mode coverage stays explicit. App-written XMP-only label
   clears work; external empty element-form Label parsing remains an interoperability follow-up.
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
| Storage, cancellation and integrity | Open | Remaining writer completion/ownership and real-volume drills |
| Automated regression and package | Cycle 9 regression/repository checks passed | Packaging and exact-candidate release checks remain |
| Computer-use workflows | Narrow native lifecycle checks passed | Remaining required workspaces, failures/recovery and authentic fixtures |
| Accessibility/layout/display | Open | Full keyboard/VoiceOver, IME, contrast/motion, window/display evidence |
| Performance/supported hardware | Open | Target tiers/budgets and measured workloads |
| External interoperability/transport | Open | Actual Bridge/Photo Mechanic and disposable FTP/FTPS/SFTP evidence |
| Model distribution/offline lifecycle | Open | Required signed artifact/server/install/offline/update/rollback evidence |
| Privacy/legal/remote CI | External dependency | Qualified review and authorized remote configuration evidence |
| Final user acceptance | Not started | Candidate-specific HTML results after readiness decision |
| Signing/notarization/distribution | After applicable gates | Separate authorization and release-plan evidence |

## Blocker tracking

Cycle 10 resolved cycle 9's native lock/setup blocker. Preferences are restored, the exact
rotation binary passed the recorded cases and all native QA app entries are stopped. Historical
cycle-9 notes below describe that earlier state, not an outstanding cleanup task.


Cycle 9 native launch/open succeeded. Settings showed Professional selected, then the Custom
click returned locked-Mac; a later recheck remained locked. No rotation command ran. Original
PNG/JSON fixture bytes are unchanged, but the preference click outcome and app shutdown remain
unverified. On access return inspect Settings, finish the native case, restore Professional and
the original Custom standard-image write setting, return General, and quit normally. This is
one blocked verification path; implementation work remains and the automation stays active.


Cycle 6's final recovery build could not launch while the Mac was locked. Access resumed at the
first cycle-7 recheck, and native recovery passed with exact fixture hashes after relaunch. No
unlock bypass was used. The Mac locked again before final cycle-7 Face retesting and remained
locked on the first cycle-8 check. Later access resumed; final Face34a and explicit-clear native
checks pass. No user action remains for these temporary host limitations.

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
at setup. Do not bypass with another route. Static checks passed for 31 complete cases, unique
IDs, local source links and JavaScript syntax. It remains unassigned to a candidate and all
human results are unrun.

Consecutive runs with no possible progress: 0. Substantive implementation and verification
progress occurred. Automation remains active; no readiness notification is warranted.

## Latest handoff

Cycle-10 interruption/resumption checkpoint: native rotation is complete as recorded above.
The fixture has now been intentionally changed: known/unknown source orientation is 6/8,
matching XMP companions exist, typed drafts are removed, captions remain pending, original
snapshots and pixel payloads are unchanged. Final `cycle10-after-apply-snapshot.json` and
`cycle10-after-final-relaunch-snapshot.json` match. Preferences restored; QA app stopped.
Core agent owns CaptionSession/MetadataSidecarService replay evidence and tests; Browser agent
owns MetadataReviewView/BrowserViewModel/caller tests; parent owns ContentView/FolderTreeRow
lifecycle integration and automatic-save tests. These uncommitted changes need build, tests,
independent review and native testing before integration is called complete.

The following cycle-9 handoff is retained as historical baseline information:


Source `b5840e4304450dce9371b5c2329e230635adf351` contains sixteen reviewed source/test files.
The integrated suite passes 2,569 tests / 285 suites in 89.697 seconds; final Browser focused
checks pass 15 tests, core checks pass after their fixture correction, and repository checks pass.
Logs use `/private/tmp/aagedal-coordinator-cycle9-*.log`; exact initial failures and corrections
are in the dated report. Do not rerun unchanged automated checks merely because a heartbeat fires.

`build/qa-rotation-cycle9/` is the new untouched known/null-snapshot native fixture set. Read its
`tested-binary-identity.json` before native continuation. The app was left in Settings after the
Custom click returned host-locked; neither click outcome nor shutdown is verified. Professional
was selected immediately before that click. Original Custom Standard Images = Write to Image File,
RAW/C2PA = XMP. Finish/restore through the UI when available; no unlock bypass or global reset.
`before-native-snapshot.json` and `after-native-attempt-snapshot.json` match all four original
artifacts. The inspector in `build/qa-rotation-cycle9-tools/inspect.py` now includes orientation
carriers and pixel payload hashes. No native rotation/write result is claimed yet.

Cycle-8 label-clear and Face fixtures retain their passing evidence. Their binaries differ from
the current build; do not describe the current app as the cycle-8 identity. Earlier Caption,
Browser, Trash and recovery evidence remains in its dated reports. No production transfer,
publication, private-photo change or final user acceptance occurred. The HTML remains unassigned
to a final candidate, with 31 cases and human results unrun. Sixty unchecked authoritative plan
entries remain; no-progress count is zero and the coordinator automation stays active.
