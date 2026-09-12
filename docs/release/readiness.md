# 3.0 coordinator state

**State:** IMPLEMENTING — Known People archive, tracked capture and managed replacement are committed and verified; identity assignment, UI and cloud reconciliation remain.
**Updated:** 2026-09-12
**Latest implementation commit:** `75efdb4` (2,781 tests / 304 suites and repository checks passed).
**Latest native evidence:** `ae99369` masked save, Undo on exit, genuine external conflict, failed Quit/navigation refusal, recovery cancel/export/tamper/scoped discard, fresh save, dual Reset and exact relaunch persistence pass. No preferences changed; QA apps stopped. `be970f0` verifies warning retention after failed recovery and clearance after verified discard/fresh save.
**Cycle baseline:** `78f0209` on `main`; cycle 16 Known People core committed and validated as `75efdb4`.
**Coordinator task:** `01a087bc-ce74-72d2-9c16-829b5a984ff9`
**Automation:** `aagedal-photo-agent-3-0-coordinator` — active, every 10 minutes in this task (saved schedule rechecked).

## Current evidence

[Known People companion interchange](known-people-companion-interchange-design.md)
records the exact FTP Sync schema-2 projection, lossless Photo Agent extension,
replacement semantics and later opt-in App Group channel. Strict shared FEM2 admission
is implemented and independently reviewed. Fresh Photo Agent detections now persist exact
model/preprocessing provenance from the declaring embedder through Known People addition,
while cached legacy samples remain honestly unknown. Whole-library eligibility now rejects
invalid names/IDs, empty people, unknown provenance and invalid FEM2. The current Known People
core checkpoint adds strict ZIP32 transport, descriptor-bound whole-root replacement, exact
admitted-package retention, tracked local capture, route/iCloud exclusion, generation invalidation
and the exported `.aagedalpeople` package type. The integrated focused run passes 149 declared
tests across 346 expanded cases; repository checks and independent source review pass.
The compatible companion contract is pinned to FTP Sync `2dc18e9` after its full suite
passed. Its strengthened golden directory is pinned at `da3579e`; Photo Agent admits that
fixture byte exactly through a strict no-follow directory reader and re-exports the captured
bytes through an atomic directory writer. Reader and writer suites pass 10 and 13 tests,
including 37 writer fault, alias, cancellation, retargeting, mutation and cooperative-serialization
cases. The writer's retained parent descriptor and advisory lock cover cooperating writers;
non-cooperating same-user mutation remains outside the whole transaction guarantee, with observed
boundary changes rejected while recovery evidence is retained. First-time identity assignment,
explicit local-to-cloud reconciliation and UI adapters remain gated. A pinned color-asymmetric fixture now proves the RGB contract against Torch
and Core ML with a BGR negative control, and two independent locked builds produce identical bytes
and receipts. The reviewed deterministic model now replaces the contradictory local artifact and all
declared hashes match. The checked-in compact reference now passes the app's exact `CGImage` preprocessing
and model-backed embed path with the BGR-negative separation, and a clean-source driver makes the two-process
evidence repeatable. Hardened streaming/archive installation and a production distribution key/signature
remain open recognition gates.

[Cycle 15 Primary retention](cycle-15-primary-develop-retention-2026-09-11.md) implements immutable original evidence, causal FIFO, lifecycle capture/barriers and verified export-before-discard recovery. Independent review, 103 focused tests, 2,687 integrated tests and repository checks pass for `ae99369`. Native save/Undo, real conflict retention, blocked Quit/workspace/selection, recovery cancellation/tamper/scoped discard, fresh save, dual Reset and relaunch pass. The separate `be970f0` notice fix passes independent review, 51 focused tests, 2,687 integrated tests, repository checks and a native tamper/refusal/discard/fresh-save regression. The earlier usage interruption and an unchanged Known People wait failure followed by passing reruns remain explicitly recorded.

[Cycle 14 XMP baselines](cycle-14-xmp-baselines-2026-09-11.md) captures exact load-time bytes,
propagates verified receipts and prevents stale technical intent from adopting Caption/Variables
physical results. Restore admission also uses exact bytes. Independent review passes, focused v3
passes 121 tests / five suites, full passes 2,666 tests / 295 suites in 96.165s, repository checks pass.
Native masked reset/repeated save, genuine external refusal, fresh reload/retry, embedded reset
and relaunch pass. All artifacts match after final relaunch; no preferences changed; QA apps stopped.
At the cycle-14 checkpoint, a genuine failed Develop reset could be lost on normal Quit.
Cycle 15 above fixes and verifies that retention defect.


[Cycle 13 variable recovery](cycle-13-variable-recovery-2026-09-11.md) adds complete private exports,
settled review ownership and exact-photo discard with native buffer and deferred shared-template
cleanup guards. Independent review passes; focused v3 passes 61 tests / six suites, integrated
passes 2,654 tests / 293 suites in 98.963s and repository checks pass. Native permanent conflict,
Cancel/save-panel Cancel, mode-0600 export, tamper rejection, A-only discard, B-only repair/retry
and normal quit/relaunch pass. All artifacts remain identical after relaunch and QA apps are stopped.
Intermediate v2 stack exhaustion and fixture/expectation errors are documented and corrected.


[Cycle 12 variables](cycle-12-variables-2026-09-11.md) captures immutable input/folder/policy,
awaits full-record JSON/physical verification, retains retry/partial receipts and guards Close/Quit
while unverified unsaved work is retained. Template lists, >20 deltas, original provenance and
prior clear/overwrite composition are corrected. Independent review passes, focused v4 passes
134 tests / seven suites, focused roster passes seven tests, full v2 passes 2,633 tests / 291 suites
in 99.012s and repository checks pass. Native physical partial failure/repair, JSON-only History
Only, literal lists/originals/opaque/history/pixels, preference restoration and relaunch pass.
At that checkpoint all app entries were stopped. Cycle 13 above completes bounded permanent conflict
recovery; broader native cases remain mandatory. Transient menu access recovered after normal quit/relaunch.


[Cycle 11 native Review recovery](cycle-11-review-recovery-native-2026-09-11.md) passes on
unchanged `f897bdd`: JSON-only partial failure blocks exit; retry completes both photos without
duplicate history; applied-witness retry preserves a newer record; a replaced history creates a
permanent conflict, Cancel/Save-panel Cancel retain work, verified export enables scoped discard,
and external A plus other queued B survive normal quit/relaunch with identical artifacts. Native
session reset restored access, all obstructions are removed, no preferences changed, and the QA
app is stopped. More than 20 native fields, IME/VoiceOver and in-flight disappearance remain open.

[Cycle 11 Write All](cycle-11-write-all-2026-09-11.md) fixes the RAW silent-skip/data-loss path
and stale-XMP shadowing through strict discovery, fresh credential facts, exact source/JSON/XMP
admission and verified full editorial completion. Records retain history, opaque JSON and known/null
originals. Independent batch details remain available after selection changes. The stronger mask
fixture exposed unstable parsed mask IDs; exact XMP byte snapshots fix Write All admission without
weakening preservation checks. Independent review passes; focused v2 passes 91 tests / five suites,
full suite passes 2,602 tests / 288 suites in 94.961s and repository validation passes. Native
wrote-2/failed-1 reporting, unchanged failed files, selection-independent details, repair-only retry,
explicit label clear and full relaunch persistence pass on the committed binary. All QA app entries
are stopped; no preference change or temporary obstruction remains. Real RAW/credential/native
cancellation/performance cases remain separately unverified.

[Cycle 10 Metadata Review](cycle-10-metadata-review-2026-09-11.md) implements retained live row
buffers, shared replay/receipt/recovery, source evidence for first records and lifecycle/mutation
barriers. Independent review passes after resolving stale row callbacks, full-value rebasing and
recovery freeze lifetimes. Focused 57 tests and full 2,585 tests pass; repository checks pass.
Native edits survive workspace exit and normal quit/relaunch with known/null/first originals,
unchanged PNGs and untouched-row no-write behavior. At the cycle-10 checkpoint, native failure/recovery was unrun after
the connection stopped returning usable state/screenshots. Cycle 11 above now supplies that
evidence and records the intentionally changed disposable failure fixture.

[Cycle 10 native continuation](cycle-10-rotation-native-2026-09-11.md) resolves the rotation setup
blocker on unchanged `b5840e4`. History-only angles 6/8 survive full-screen and relaunch; Write All
reports the full refusal and preserves all artifacts. Explicit same-target dual apply writes EXIF
and both XMP conventions, removes only rotation intent, preserves G/null snapshot/history/pixels,
and survives reopening. Original Professional/Custom preferences and General page are restored;
native inventory confirmed the rotation QA app stopped at that checkpoint. The later Review
shutdown status is recorded above. Other listed tasks use separate repositories.


[Cycle 9](cycle-09-durable-rotation-2026-09-11.md) implements ordered Browser rotation, a durable
technical JSON draft, per-destination retry baselines, same-target Write Pending Rotation, and
thumbnail/full-screen pending orientation. Caption and null snapshots survive; complete-record
writes/export/FTP admission require pending rotation to be applied first. Full checks pass 2,569
tests / 285 suites and independent review passes. Two new fixture construction defects were
corrected and documented; no product assertion was suppressed. The exact final build launched
and opened the disposable folder, then the Mac locked on the Custom preset click. At the cycle-9 checkpoint rotation and preference cleanup were unverified; cycle 10
subsequently completed those checks as recorded above. The earlier unchanged fixture state is
historical, not the current rotation artifact state.



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

1. Coordinate and implement the versioned Known People `.aagedalpeople` interchange in
   [the companion design](known-people-companion-interchange-design.md). FTP Sync has a
   committed compatible editor-payload contract at `2dc18e9` and strengthened golden directory
   at `da3579e`; Photo Agent's strict directory admission and atomic exact-byte directory writer
   now pass that fixture. Photo Agent's strict ZIP32 archive, managed-store replacement and
   tracked local snapshot builder and atomic first-time identity assignment pass integrated review
   and tests. Implement unified package admission/export service APIs, explicit local-to-cloud
   reconciliation and the Settings/Expanded Known People import/export controller next, including
   the coordinated 65,534-entry archive limit.
   Review and replace the pinned model with the independently reproduced RGB artifact before enabling
   production companion recognition; the image-to-reference proof and deterministic receipt now pass.
   Legacy Photo Agent imports also lack trustworthy embedding-space provenance.
   Resolve those gates before claiming compatible or lossless exchange. Automatic local sync
   remains a separate opt-in App Group phase after both signed targets share one entitlement.
2. Extend Develop native coverage to named-version failed transitions and crop changes during
   drag. Cycle 15 closes failed-save retention, Undo-on-exit and stale recovery notices;
   do not repeat unchanged automated suites without a relevant change.
3. Complete remaining variable native cases: focused live-field commit, >20-field templates,
   in-flight cancellation/selection, authentic RAW/C2PA and accessibility/performance. Cycle 12's
   physical/error/repair/History Only/relaunch cases pass on `fbe253f`; do not rerun unchanged full
   checks without a relevant change. Review lifetime/IME and Write All's broader cases remain separate.
4. Complete remaining Sony companion archive and source reassociation using the source-backed
   [archive design](voice-memo-archive-design.md). Ingest, rename, Duplicate, Move, Reject and
   memo Trash now have implementation. Preserve explicit ownership through rendering/signing/
   cleanup; schema-1 filename hints alone cannot establish historical reassociation identity.
5. Implement cancellable local transcription with explicit language/model/offline state,
   review-before-apply and transcript provenance, following the [SDK-backed design](voice-memo-transcription-design.md).
   Integrate reviewed transcript variables and visible Deadline WAV delivery policy/receipt.
6. Continue actual UI checks across required workspaces and failure/recovery cases, plus remaining
   storage/executor auditing. Cycle 3 observed native Trash, shared survivor playback, missing-memo
   Details, Finder Put Back, exact bundle recovery and restored Caption persistence. Broaden to
   real Sony, long error scrolling, face-group Trash, Bridge/Photo Mechanic, disposable transports,
   accessibility/IME/display, solar/reports and measured performance. Narrow evidence is not a full gate.
7. Establish missing hardware/model-lifecycle/privacy/remote-CI evidence. Qualified legal review
   and protected remote branch enforcement remain external prerequisites. Complete independent
   work before an actionable blocker handoff; do not silently move mandatory gates to acceptance.
8. Once unconditional gates pass, obtain independent readiness review, build/launch the exact
   candidate, finalize and visually verify the [HTML checklist](manual-testing-checklist.html),
   then follow [the coordinator protocol](coordinator.md) before notifying for acceptance.

## Open gate groups

| Gate | Current disposition | Required evidence |
| --- | --- | --- |
| Required features | Open | Archive/reassociation, transcription, reviewed variables and delivery; inventory dispositions |
| Storage, cancellation and integrity | Open | Remaining writer completion/ownership and real-volume drills |
| Automated regression and package | Cycle 14: 2,666 tests and repository checks passed | Packaging and exact-candidate release checks remain |
| Computer-use workflows | Narrow native lifecycle checks passed | Remaining required workspaces, failures/recovery and authentic fixtures |
| Accessibility/layout/display | Open | Full keyboard/VoiceOver, IME, contrast/motion, window/display evidence |
| Performance/supported hardware | Open | Target tiers/budgets and measured workloads |
| External interoperability/transport | Open | Actual Bridge/Photo Mechanic and disposable FTP/FTPS/SFTP evidence |
| Model distribution/offline lifecycle | Open | Required signed artifact/server/install/offline/update/rollback evidence |
| Privacy/legal/remote CI | External dependency | Qualified review and authorized remote configuration evidence |
| Final user acceptance | Not started | Candidate-specific HTML results after readiness decision |
| Signing/notarization/distribution | After applicable gates | Separate authorization and release-plan evidence |

## Blocker tracking

Cycle 11 restored native access by resetting only the CUA session and using native keyboard menu
selection where IDs went stale. Ordinary Review failure/recovery is complete; final shutdown is
confirmed and test preferences are unchanged. The earlier connection limitation below is historical.

Historical cycle-10 native connection limitation: while opening the Review failure fixture, menu IDs became
invalid and blank/stale window state plus unavailable screenshots persisted after reconnect.
A later normal Escape/Command-Q retry succeeded; final native inventory confirms all QA app entries stopped. No Review
preferences or failure files were changed. Retry through native UI when available; independent
implementation remains possible, so this is not total blockage and no readiness alert is due.

Historical native checkpoints follow:

Cycle 10 resolved cycle 9's native lock/setup blocker. Preferences are restored, the exact
rotation binary passed the recorded cases and all native QA app entries were stopped then. Historical
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
at setup. Do not bypass with another route. Static checks now pass for 35 complete cases, unique
IDs, local source links and JavaScript syntax. It remains unassigned to a candidate and all
human results are unrun.

Consecutive runs with no possible progress: 0. Substantive implementation and verification
progress occurred. Automation remains active; no readiness notification is warranted.

## Latest handoff

The Known People core interchange checkpoint is implemented on source based at `78f0209`
and recorded in [cycle 16](cycle-16-known-people-core-2026-09-12.md). Directory packages
and strict STORED ZIP32 transport preserve exact admitted bytes; managed replacement owns
the route and whole local root, retains the displaced root as recovery evidence, discards
stale deferred work and blocks iCloud enablement until explicit reconciliation. Tracked
local capture binds both the admitted package and uppercase service-local projection while
keeping lowercase package paths. The final focused run passes 149 declared tests / 346
expanded cases across five suites, independent review passes, and repository validation
passes. The complete post-fix suite result is recorded in cycle 16.

Atomic first-time identity assignment for untracked populated or empty stores is complete and
recorded in [cycle 17](cycle-17-known-people-identity-2026-09-12.md):
preparation is read-only, binds the exact captured inventory across planning, generates stable
IDs once, and commits only through the existing owner gateway. Precommit retry retains those IDs;
committed uncertainty is returned without replay. The identity/builder/replacement checkpoint
passes 46 declared tests / 84 expanded cases and independent review. The next bounded work is
the high-level admission/export service API and Settings/Expanded Known People UI.
The archive contract is 65,534 entries because `0xffff` is the ZIP64 sentinel; directory
packages retain the 200,001-file schema cap. The companion app and UI must present the same
limit. Explicit local-to-cloud reconciliation and later opt-in App Group publication remain
separate. Production AuraFace distribution trust and legacy embedding provenance remain open.

`ae99369` is committed and independently reviewed. Focused-v4 passes 103 tests / five
suites; full-v3 passes 2,687 tests / 297 suites in 102.945s and repository-v2 passes.
Full-v2 had one unchanged Known People timed-gate failure; isolated 64 tests and full-v3
pass without changing its assertion or timeout. No claim of proven root cause is made.

Native evidence under `build/qa-primary-develop-cycle15` confirms the previously lost
failed Primary edit now blocks normal Quit after alert dismissal, workspace exit and
photo navigation. Retry uses original evidence; verified export and exact discard
preserve every photo artifact. Undo reaches XMP on exit; fresh saves, dual Reset and
normal relaunch retain captions, masks where expected, opaque data and pixels. All
photo artifacts are identical after relaunch and every Photo Agent app is stopped.

The native run found stale Primary notice text after successful recovery. Committed
`be970f0` separates notice ownership; independent review, 51 focused tests / four suites
(4.797s), 2,687 integrated tests / 297 suites (92.351s) and repository checks pass.
Fresh native fixtures in `build/qa-primary-develop-cycle15-notice` verify the warning
survives tampered-export refusal and Cancel, clears after verified scoped discard,
and stays clear after a fresh save. Discard preserves all photo artifacts exactly;
Undo is disabled afterward and normal Exit/Quit succeeds. All QA apps are stopped.
This final view-only regression did not repeat the earlier relaunch sequence.
No source is dirty. No preferences changed. The retained API's
currently tested UI routes are XMP and dual; file-only orientation chaining is a latent
unsupported-route limitation, not claimed as verified behavior.

All four plans retain 60 open criteria (9/23/22/6). HTML has 35 cases with results and
candidate unassigned; final interactive checklist validation remains pending. The
no-progress counter is zero and the existing heartbeat remains active. Broader native,
voice/transcription/delivery, external interoperability and release gates remain open.

## Companion integration follow-up — 2026-09-12

The FTP Sync coordinator reports local matcher/FEM2 codec work in its separate
checkout and requests a Known People interchange v2 exporter integration review.
Its proposed contract is in that project's
`Documentation/Testing/3.0-M0-Face-Compatibility.md` (reported source `a7392e3`):
model, embedding-space and preprocessing identity, persistent library ID/revision,
payload hashes, and replacement semantics for removals/renames. This is a queued
compatibility review, not verified exporter support or a checked acceptance gate.
No Photo Agent files were delegated to that task and desktop ownership remains here.
