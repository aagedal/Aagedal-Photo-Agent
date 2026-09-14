# 3.0 coordinator state

**State:** IMPLEMENTING — Known People interchange/cloud reconciliation, transactional voice-memo archive/recovery/reassociation, local transcription, durable reviewed approval, exact-approved transcript-variable resolution, pre-mutation application preview, native single- and multi-image application/read-back with invalid-authority refusal, and explicit verified WAV delivery pass verification; authentic Sony/real-server voice-memo evidence, cloud and broader release gates remain.
**Updated:** 2026-09-14
**Latest implementation state:** Cycle 32 voice-memo batch application (2,907 tests in the serial run, the focused native batch test and repository checks passed; the built app now verifies missing, unapproved and stale whole-batch refusal plus exact two-photo application; independent review and offline/Sony/VoiceOver evidence remain open). Cycle 31's 10-test pass remains the latest complete UI-smoke-target result because an unrelated foreground app interrupted cycle 32's whole-target attempt.
**Latest native evidence:** Cycle 32 refuses a two-photo selection when either authority is missing, unapproved or stale, preserving both complete bundles byte for byte, then applies two distinct approved reviews as eight exact field changes while preserving both relationship records and WAVs. Cycle 31's cancel/confirm/read-back, cycle 30's review/approval, cycle 18's Known People interchange and cycle 15's Primary/Develop recovery evidence remain valid.
**Cycle baseline:** `78f0209` on `main`; cycles 16–19 advance Known People interchange, cycle 20 adds transactional RAW voice-memo archive preservation, cycle 21 adds identity-bound adjacent memo recovery, cycle 22 adds exact moved-relationship reassociation, cycle 23 adds local editable transcription, cycle 24 adds durable reviewed approval, cycle 25 adds the exact-approved shared transcript variable, cycle 26 adds compatible-target enforcement plus its pre-mutation preview, cycle 27 adds explicit verified WAV delivery, cycle 28 adds the transcription failure/reservation matrix, cycle 29 makes incremental review edits durable through navigation and relaunch boundaries, cycle 30 closes the native review/relaunch/approval check, cycle 31 closes the narrow native variable application/read-back check and cycle 32 closes native invalid-authority refusal plus two-photo application.
**Coordinator task:** `01a087bc-ce74-72d2-9c16-829b5a984ff9`
**Automation:** `aagedal-photo-agent-3-0-coordinator` — active, every 10 minutes in this task (saved schedule rechecked).

## Current evidence

[Cycle 32 voice-memo batch application](cycle-32-voice-memo-batch-application-2026-09-14.md)
closes the native missing/unapproved/stale authority-refusal and two-photo application checkpoint.
Three invalid fixtures each refuse the complete selection with zero writes and preserve both image,
sidecar, relationship and WAV bundles byte for byte. Two approved fixtures produce an exact eight-field
Replace preview and persist each photo's distinct review while retaining exact relationship and WAV
bytes. The 2,907-test serial suite, focused native batch test and repository validation pass. The
whole UI target was interrupted by unrelated desktop focus, so cycle 31's 10-test run remains the
latest complete whole-target evidence. Offline recognition, authorized-Sony recovery, VoiceOver and
real-server evidence remain open.

[Cycle 31 native voice-memo application](cycle-31-voice-memo-native-application-2026-09-13.md)
closes the narrow built-app variable application/read-back check. The fixture previews exact Replace
and Append effects, cancels with Escape without changing image or sidecar bytes, confirms with Return,
persists all four supported fields and reads them back after relaunch while retaining exact
relationship and WAV bytes. The template store is isolated behind a gated UI-test launch argument,
and a focus-loss debounce no longer sweeps later template mutations into an editor save. The
2,906-test serial suite, all 10 UI smoke tests and repository validation pass. Offline recognition,
authorized-Sony recovery, broader accessibility and real-server evidence remain open.

[Cycle 30 native voice-memo approval](cycle-30-voice-memo-native-approval-2026-09-13.md)
closes the dedicated native edit/relaunch/approval check and preserves the relationship plus WAV
bytes exactly. It fixes false post-write corruption when production subsecond dates are canonicalized
to whole-second ISO-8601 storage, returns the installed canonical transcript, reopens a remembered
closed main window in UI tests and preserves Browser search focus across no-results transitions. The
2,905-test serial suite, all 9 UI smoke tests and repository validation pass. Offline recognition,
authorized-Sony recovery, transcript application/read-back, accessibility and real-server evidence
remain open.

[Cycle 29 voice-memo review edit durability](cycle-29-voice-memo-review-edit-durability-2026-09-13.md)
serializes incremental edits after approval revocation toward the latest complete review. Photo and
locale transitions await that durability boundary, transcription replacement is unavailable while
it saves, and failure restores the latest durable state. The focused 19-test run, 2,904-test serial
suite and repository validation pass. The dedicated native edit/relaunch test compiles, but its run
stopped before product assertions because the locked Mac prevented app activation. Native/offline,
authorized-Sony, application/read-back and accessibility evidence remain open.

[Cycle 28 voice-memo transcription failure matrix](cycle-28-voice-memo-transcription-failure-matrix-2026-09-13.md)
splits recognition into injectable consumer, analysis, finalization and cancellation/finish phases,
with one idempotent teardown and privacy-safe typed failures. Caption now detects Apple speech-language
reservation exhaustion and offers explicit release before retrying download. The exact final focused
18-test run, 2,903-test serial suite and repository validation pass. Native/offline, authorized-Sony,
relaunch/application and accessibility evidence remain open.

[Cycle 27 visible voice-memo delivery policy](cycle-27-voice-memo-delivery-policy-2026-09-13.md)
adds profile-level exclude, include-when-available and require-for-every-image choices with safe
legacy exclusion. Preflight, confirmation, exact frozen planning, verified staging, sequential
upload, resumable checkpoints and schema-3 receipts carry the disposition without silent omission.
Activity and exported summaries retain only anonymous audio evidence. The focused 123-test run,
2,896-test serial suite and repository validation pass. Independent review, native/relaunch and
disposable real-server image-plus-WAV evidence remain open.

[Cycle 26 voice-memo transcript application preview](cycle-26-voice-memo-variable-preview-2026-09-13.md)
preflights and revalidates every transcript-bearing photo before showing exact Append/Replace
before/after values. The four supported editorial-prose destinations are enforced in the model and
template editor. Cancel executes no write; one invalid authority refuses the complete batch before mutation;
Confirm uses the frozen requests and checks the authority set again. The focused 47-test run,
adjacent 84-test regression, 2,889-test serial suite and repository validation pass. Native/relaunch
application, accessibility, transcription failure breadth and Deadline WAV policy remain open.

[Cycle 25 exact-approved voice-memo transcript variable](cycle-25-voice-memo-transcript-variable-2026-09-13.md)
adds `{voiceMemoTranscript}` to the shared catalog and interpolator. Per-photo resolution accepts only
an explicitly approved review after exact relationship/WAV validation, retains that authority with
the immutable write request, and revalidates it before initial or retried metadata execution.
Transcript braces remain literal. The focused 55-test run, 2,886-test serial suite and repository
validation pass. Dedicated affected-image preview, compatible-target presentation, native/relaunch
application, failure-matrix breadth and Deadline WAV policy remain open.

[Cycle 24 durable voice-memo transcript review](cycle-24-voice-memo-transcript-review-2026-09-13.md)
stores generated/reviewed provenance only after explicit approval in a versioned, exact-WAV-bound
app-sidecar extension. Editing revokes approval; failed replacement retains the prior record. The
existing serialized photo transaction and cleanup/copy/relocation paths preserve opaque fields, while
newer nested schemas remain read-only. Thirteen focused tests, 61 broader tests, the 2,879-test serial
suite and repository validation pass. Transcript variables/application, Deadline WAV policy and
native/offline/Sony evidence remain open.

[Cycle 23 voice-memo transcription foundation](cycle-23-voice-memo-transcription-foundation-2026-09-13.md)
adds explicit Apple on-device language readiness/download and cancellable WAV analysis on a retained
utility executor. Exact WAV revision plus current association are checked before an editable draft is
published, navigation rejects late results, and generated versus edited text/provenance remain distinct.
The draft cannot persist or mutate metadata. Six focused tests, 13 adjacent playback tests, the exact
2,872-test serial suite and repository validation pass. Durable reviewed approval, sidecar/variable/
delivery integration and native asset/offline/authorized-Sony evidence remain open.

[Cycle 22 voice-memo reassociation](cycle-22-voice-memo-reassociation-2026-09-13.md) adds a
Caption folder picker for moved hidden relationships. One exact photo/WAV identity pair commits a
verified adjacent copy and rewritten record; duplicate exact, changed and missing results fail
closed. Path/resource hints remain non-authoritative, selected sources and opaque record fields are
preserved, and exclusive installation has owned rollback plus stale-navigation rejection. The 51
affected tests, exact 2,866-test serial suite and repository validation pass. Native picker,
authorized Sony media, relaunch/accessibility and physical-volume evidence remain open.

[Cycle 21 voice-memo recovery](cycle-21-voice-memo-recovery-2026-09-13.md) adds compatible
schema-2 photo/WAV identities and provenance, then lets Caption recover a persisted missing memo
from an explicitly selected WAV. Exact bytes restore automatically; changed or legacy evidence
requires explicit replacement and clears any approval tied to the prior audio hash. Copy/stage/hash/
exclusive-install/read-back and rollback preserve the selected source and prior record on failure;
stale navigation cannot publish or commit recovery. The affected 56-test roster, exact 2,859-test
serial suite and repository validation pass. General relocated-photo/record discovery, native UI,
real Sony/volume evidence and independent review remain open.

[Cycle 20 RAW voice-memo archive](cycle-20-voice-memo-raw-archive-2026-09-12.md) routes all six
JPEG XL, TIFF and DNG archive commands through one utility-executor transaction. It freezes source
image/XMP/relationship/memo evidence, stages under the final basename before optional C2PA signing,
revalidates rendered bytes, and installs or rolls back the complete image/XMP/WAV/record bundle.
The archive suite passes 12 tests; the exact integrated run passes 2,851 tests in 131.125 seconds,
and repository validation passes. Real RAW/DNG Converter/C2PA, physical-volume crash recovery,
archive playback after source loss and independent review remain open; cycle 21 adds adjacent
missing-memo recovery but not general relocated-photo/record discovery.

[Known People companion interchange](known-people-companion-interchange-design.md)
records the exact FTP Sync schema-2 projection, lossless Photo Agent extension,
replacement semantics and later opt-in App Group channel. Strict shared FEM2 admission
is implemented and independently reviewed. Fresh Photo Agent detections now persist exact
model/preprocessing provenance from the declaring embedder through Known People addition,
while cached legacy samples remain honestly unknown. Whole-library eligibility now rejects
invalid names/IDs, people without examples, unknown provenance and invalid FEM2. The current Known People
core checkpoint adds strict ZIP32 transport, descriptor-bound whole-root replacement, exact
admitted-package retention, tracked local capture, route/iCloud exclusion, generation invalidation
and the exported `.aagedalpeople` package type. The integrated focused run passes 149 declared
tests across 346 expanded cases; repository checks and the earlier core source review pass.
The compatible companion contract is pinned to FTP Sync `2dc18e9` after its full suite
passed. Its strengthened golden directory is pinned at `da3579e`; Photo Agent admits that
fixture byte exactly through a strict no-follow directory reader and re-exports the captured
bytes through an atomic directory writer. Reader and writer suites pass 10 and 13 tests,
including 37 writer fault, alias, cancellation, retargeting, mutation and cooperative-serialization
cases. The writer's retained parent descriptor and advisory lock cover cooperating writers;
non-cooperating same-user mutation remains outside the whole transaction guarantee, with observed
boundary changes rejected while recovery evidence is retained. First-time identity assignment,
strict directory/archive admission, high-level export preparation and the shared Settings/Expanded
Known People UI now pass automated and native checks. Explicit local-to-cloud replacement now
publishes a complete isolated generation behind a strict active pointer and clears the local gate
only after verified publication; its automated checks pass, while native iCloud/multi-Mac evidence
remains gated. A pinned color-asymmetric fixture now proves the RGB contract against Torch
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
   tracked local snapshot builder, atomic first-time identity assignment, unified package
   admission/export service APIs and the Settings/Expanded Known People controller pass integrated
   review, automated tests and disposable-root native checks. Explicit local-to-cloud reconciliation
   is implemented and passes the complete automated suite; exercise it with disposable real iCloud
   and multi-Mac interruption/removal cases next, and coordinate the presented 65,534-entry archive
   limit with FTP Sync.
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
4. Complete general Sony companion source reassociation using the source-backed
   [archive design](voice-memo-archive-design.md). Cycle 20 implements shared transactional RAW
   archive preservation and cycle 21 implements identities plus adjacent missing-memo recovery.
   Cycle 22 adds user-scoped relocated-photo/record discovery with explicit ambiguous/changed/missing
   states and an exact-copy transaction. Exercise it with the native picker and authorized Sony
   samples, then cover real JPEG XL/TIFF/DNG, DNG Converter, C2PA and physical-volume interruption/
   playback cases; schema-1 filename hints alone cannot establish historical identity.
5. Continue the local transcription slice following the [SDK-backed design](voice-memo-transcription-design.md).
   Cycles 23–26 implement explicit runtime language/asset state, download, cancellable analysis,
   exact-WAV validation, editable review, serialized provenance, explicit approval and edit-triggered
   revocation, exact-approved shared transcript-variable resolution with retry revalidation, and
   compatible-target exact affected-image Append/Replace preview with zero-write batch refusal.
   Cycle 27 adds the visible Deadline WAV delivery policy/receipt and exact verified execution.
   Cycle 28 completes the injected malformed/empty/finalization/install-cancellation/reservation
   matrix with a single-teardown recognition lifecycle. Cycle 29 serializes every incremental review
   edit toward the latest durable unapproved text, waits before photo/locale transitions and blocks
   replacement transcription during persistence. Cycle 30 completes the native edit/relaunch/
   approval fixture and canonical timestamp verification while preserving exact WAV/relationship
   bytes. Cycle 31 completes a narrow native application drill: exact Replace/Append preview, Escape
   cancellation, Return confirmation, all four compatible destinations and relaunch read-back.
   Cycle 32 extends that native path to two-photo selection, all-or-nothing missing/unapproved/stale
   authority refusal and two distinct approved reviews applied as eight exact field changes. Continue
   native offline/Sony drills plus VoiceOver evidence and native and real-server image-plus-WAV
   delivery.
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
| Required features | Open | Transcription/reviewed-variable native breadth; authentic reassociation/archive/delivery evidence; inventory dispositions |
| Storage, cancellation and integrity | Open | Remaining writer completion/ownership and real-volume drills |
| Automated regression and package | Cycle 32: 2,907 serial tests, focused native batch test and repository checks passed; cycle 31 retains the latest complete 10-test UI run | Complete UI target rerun, packaging and exact-candidate release checks remain |
| Computer-use workflows | Native voice-memo review/approval, single- and two-photo application, invalid-authority refusal/read-back and earlier narrow lifecycle checks passed | Remaining required workspaces, failures/recovery and authentic fixtures |
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
passes 46 declared tests / 84 expanded cases and independent review.

High-level admission/export and the shared MainActor UI are committed as `c87cc63` and recorded in
[cycle 18](cycle-18-known-people-service-ui-2026-09-12.md). The complete suite passes 2,832 tests /
310 suites; the integrated interchange/UI run passes 213 tests / 12 suites; repository checks and
independent review pass. Native testing in a disposable root confirms cancellation without mutation,
replacement with rollback evidence, exact visible Unicode/braces, same-library identity/count copy,
byte-exact directory export and valid STORED ZIP export. The tested app stopped cleanly.
The archive contract is 65,534 entries because `0xffff` is the ZIP64 sentinel; directory
packages retain the 200,001-file schema cap. The companion app and UI must present the same
limit. Explicit local-to-cloud reconciliation is committed as `05f484a` and recorded in
[cycle 19](cycle-19-known-people-cloud-reconciliation-2026-09-12.md): strict write-once generation
publication, cancellation-truthful pointer commit, active-generation routing and destructive UI
confirmation pass 2,839 tests / 311 suites plus repository validation. Native real-iCloud and
multi-Mac evidence, independent cycle-19 review and later opt-in App Group publication remain
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
no-progress counter is zero and the existing heartbeat remains active. Broader native, general
voice source discovery/transcription/delivery, native archive evidence, external interoperability
and release gates remain open.

## Companion integration follow-up — 2026-09-12

The FTP Sync coordinator reports local matcher/FEM2 codec work in its separate
checkout and requests a Known People interchange v2 exporter integration review.
Its proposed contract is in that project's
`Documentation/Testing/3.0-M0-Face-Compatibility.md` (reported source `a7392e3`):
model, embedding-space and preprocessing identity, persistent library ID/revision,
payload hashes, and replacement semantics for removals/renames. This is a queued
compatibility review, not verified exporter support or a checked acceptance gate.
No Photo Agent files were delegated to that task and desktop ownership remains here.
