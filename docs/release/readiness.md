# 3.0 coordinator state

**State:** IMPLEMENTING — field-only rating/label/add-person writes are committed and automated checks pass. Final native Face retest awaits desktop access.
**Updated:** 2026-09-10
**Latest implementation commit:** `34a7313a2d1d2cb01cd9cbf20e22f11a746fa249` (2,547 tests / 284 suites and repository checks passed).
**Latest native evidence:** `7a503b3` recovery PASS; cycle-7 pre-Face-correction binary Browser PASS. Final `34a7313` Face launch blocked by locked Mac; do not transfer earlier native evidence to it without retesting.
**Cycle baseline:** `53d0ef8` on `main`; clean checkout at cycle 7 start.
**Coordinator task:** `01a087bc-ce74-72d2-9c16-829b5a984ff9`
**Automation:** `aagedal-photo-agent-3-0-coordinator` — active, every 10 minutes in this task (saved schedule rechecked).

## Current evidence

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
both are corrected and independently reviewed. Final native Face testing is still required after
the Mac locked during the rebuild.

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

1. Recheck desktop access and test the exact `34a7313` build against the prepared Face fixture:
   Apply All with one blocked XMP, inspect full per-photo error, preserve destination-only names
   and pending G, remove only the disposable obstruction, retry, and verify relaunch. Recheck
   Browser persistence after the shared FaceBar change. Then continue the [field-write design](field-write-completion-design.md):
   rotation/orientation carrier, retained Metadata Review replay/recovery, batch XMP completion
   and non-displayed variables. Effective XMP-only label clear remains required; the new service
   reports retained-pending failure when embedded fallback would keep the old label.
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
| Automated regression and package | Cycle 7 final regression/repository checks passed | Native Face retest, packaging and exact-candidate launch remain |
| Computer-use workflows | Narrow native lifecycle checks passed | Remaining required workspaces, failures/recovery and authentic fixtures |
| Accessibility/layout/display | Open | Full keyboard/VoiceOver, IME, contrast/motion, window/display evidence |
| Performance/supported hardware | Open | Target tiers/budgets and measured workloads |
| External interoperability/transport | Open | Actual Bridge/Photo Mechanic and disposable FTP/FTPS/SFTP evidence |
| Model distribution/offline lifecycle | Open | Required signed artifact/server/install/offline/update/rollback evidence |
| Privacy/legal/remote CI | External dependency | Qualified review and authorized remote configuration evidence |
| Final user acceptance | Not started | Candidate-specific HTML results after readiness decision |
| Signing/notarization/distribution | After applicable gates | Separate authorization and release-plan evidence |

## Blocker tracking

Cycle 6's final recovery build could not launch while the Mac was locked. Access resumed at the
first cycle-7 recheck, and native recovery passed with exact fixture hashes after relaunch. No
unlock bypass was used. The Mac locked again before final cycle-7 Face retesting; recheck availability
next cycle while continuing independent implementation work. This is not a product failure or an
all-work blocker.

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

Source `34a7313` contains ten reviewed implementation/project/test files. The exact final Debug
3.0.0 (738) identity is `build/qa-field-write-cycle7-face/tested-binary-identity-final.json`, with
full regression and repository logs under `/private/tmp/aagedal-coordinator-cycle7-*-v2.log`.
Do not rebuild unchanged source just to resume its native test. The final build has not yet been
native-launched because the Mac locked. The QA app was quit normally and inventory confirmed
stopped before the final build.

`build/qa-field-write-cycle7-face/` retains two synthetic photos and the saved **Cycle 7 Added Person**
group. Its nonempty `failed.xmp` directory is intentional. Native Apply before the correction made
no changes because of folder URL identity; the Browser failed-rating test also preserved every
fixture byte. On corrected Apply, successful.png must append to each destination's own names and
retain pending headline G; failed.png must report failure and stay byte-identical. After preserving
failure evidence, remove only the test obstruction and retry. No model download is needed for these
saved-group metadata operations; this is not inference or authentic recognition evidence.

`build/qa-field-write-cycle7-final/` contains passing Browser read-back snapshots, unchanged pixel
payload hashes, and exact artifact equality across quit/relaunch. pending.png is 3 stars / Blue;
nil-snapshot.png is cleared / no label; both retain G pending and the latter's snapshot remains null.
Its binary identity is the pre-Face-correction build and must stay distinguished from final source.

`build/qa-caption-conflict-cycle6-final/` now contains passing recovery evidence: preserved newer A,
resumed B/C captions, verified private recovery export and exact relaunch hashes. It is no longer
an untouched fixture. Earlier cycle-3/4/5 fixture locations and intentional changes remain in their
dated reports. No private images, production destinations, remote configuration or publication
were changed. No broad gate or final user acceptance is closed. Reconcile checkout/task ownership
and native availability at the next cycle; keep the no-progress count zero and automation active.
