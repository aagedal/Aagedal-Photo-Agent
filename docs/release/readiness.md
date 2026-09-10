# 3.0 coordinator state

**State:** IMPLEMENTING — cycle 3 adds recoverable memo Trash, preserves sibling metadata and fixes automatic Caption persistence/retry defects.
**Updated:** 2026-09-10
**Latest implementation commit:** `914e99621ccd13e04df537bd903ed6d22ad4d01e` (2,449 tests / 278 suites passed).
**Cycle baseline:** `fee5b0d` on `main`; clean checkout.
**Coordinator task:** `01a087bc-ce74-72d2-9c16-829b5a984ff9`
**Automation:** `aagedal-photo-agent-3-0-coordinator` — active, every 10 minutes in this task (saved schedule rechecked).

## Current evidence

The [cycle 3 record](cycle-03-memo-trash-2026-09-10.md) identifies the implementation, independent
review, exact automated results, native interactions, artifact hashes and limitations.
The [Caption follow-up](cycle-03-caption-baseline-2026-09-10.md) records the latest integrated
source, 111 focused tests, 2,449 full tests, native unchanged-draft byte checks and real edits.
The [gate inventory](gate-inventory.md) preserves all 61 unchecked baseline criteria with
classifications and concrete next actions. Playback's narrow implementation criterion is checked;
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
The previous unrelated project ordering diff was committed separately as `fee5b0d` before this run.
No unrelated dirty source was present when cycle 3 began.

## Ordered next actions

1. Complete the explicit Restore/history replay baseline correction: those targets still use the
   selected embedded/XMP reference, which can already contain pending metadata. Test original
   snapshot A + pending/current XMP B through repeated Restore, history replay and reload, including
   intended JSON/XMP mode semantics. Include individual field pending markers: native mirrored
   drafts retain overall Pending status but lose those markers because they use the current reference.
   The separate [automatic Caption persistence correction](cycle-03-caption-baseline-2026-09-10.md)
   preserves untouched drafts and original snapshots, but does not fix those explicit targets.
   Audit shared legacy ownership in ordinary save/migration/clear paths; Move/Reject fixes do
   not establish all-writer preservation.
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
| Storage, cancellation and integrity | Open | Explicit Restore/history baseline, remaining writer ownership/recovery, real-volume drills |
| Automated regression and package | Full integrated suite passing; no candidate | Cycle 3 identifies checks; packaging and exact-candidate launch remain |
| Computer-use workflows | Narrow native lifecycle checks passed | Remaining required workspaces, failures/recovery and authentic fixtures |
| Accessibility/layout/display | Open | Full keyboard/VoiceOver, IME, contrast/motion, window/display evidence |
| Performance/supported hardware | Open | Target tiers/budgets and measured workloads |
| External interoperability/transport | Open | Actual Bridge/Photo Mechanic and disposable FTP/FTPS/SFTP evidence |
| Model distribution/offline lifecycle | Open | Required signed artifact/server/install/offline/update/rollback evidence |
| Privacy/legal/remote CI | External dependency | Qualified review and authorized remote configuration evidence |
| Final user acceptance | Not started | Candidate-specific HTML results after readiness decision |
| Signing/notarization/distribution | After applicable gates | Separate authorization and release-plan evidence |

## Blocker tracking

XCTest failed to establish its daemon control session twice before executing any tests.
[Diagnostics](cycle-03-test-launch-diagnostics.md) distinguish this from product failures.
After host access resumed, the same source passed 119 focused tests / five suites and all
2,445 tests / 278 suites. No shared daemon reset, unrelated process interruption or product
workaround was used. No user action is pending for that historical failure.
The later Caption regression executed and exposed a product deadlock, separately diagnosed and
fixed; final integrated results are 111 focused / 2,449 full tests passing. Do not confuse that
resolved defect with the earlier prelaunch environment issue.

Computer access paused for hours during a Finder call, then resumed. Recheck host/UI availability
on each run. Final stale menu references were resolved by resetting only the CUA JavaScript
session. The final QA process was quit and native inventory confirmed it stopped. Finder was
returned to its original window. Bridge is available, but presence is not interoperability proof.

Browser visual QA of the checklist remains pending: URL policy rejected its local file URL
at setup. Do not bypass with another route. Static checks passed for 29 complete cases, unique
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
The final QA process was quit normally. Other projects were building on this host later in the
run; their processes and files were left untouched. Recheck checkout/task ownership next cycle.
