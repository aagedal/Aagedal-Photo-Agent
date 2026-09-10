# Coordinator cycle 6 — scoped Caption conflict recovery

**Started:** 2026-09-10 12:38 UTC.  
**Baseline:** clean `fab8a0f` on `main`; implementation `42ace70` passed 2,512 tests / 281 suites.  
**State:** IMPLEMENTING; source independently reviewed and automated checks passed; native recovery remains pending.  
**Implementation:** `7a503b3f3eedac35b12c70edaa5ee406e4aee075`.

## Scope and reconciliation

Protocol, readiness, planning index and the four authoritative plans were reconciled. The inventory
retains 61 historically unchecked baseline criteria; current source has **60 unchecked criteria**
(9 audit, 23 investigation, 22 journalistic, 6 solar), after cycle 1 checked only narrow playback.
No additional criteria closed this cycle. Audit 66/75 and investigation delivery 119/142 remain.
The planning index and journalistic follow-up now link the latest cycle-5 evidence, correcting
stale cycle-3/4 summaries without checking broader requirements. Active task inventory shows
Media Player work in its separate checkout; no other task edits this repository.

The first required slice is scoped permanent FIFO conflict recovery. The service/queue owner
implements stable request identity, typed conflicts, frozen review, verified export and exact-set
discard. A separate caller/UI owner implements reachable review, Save panel and guarded reload.
An independent reviewer audits ownership and races. The coordinator owns desktop, builds,
integration and commits. No publication or production operations are authorized or performed.

## Native baseline

The unchanged cycle-5 Debug binary, 3.0.0 (738), was launched through native computer use.
`build/qa-caption-conflict-cycle6/` holds three copies of the existing 640×400 synthetic PNG,
initial pending JSON records and an empty directory at A's XMP path. Initial file hashes are
recorded in `initial-manifest.json`; no user photos are used.

Typing **Queued conflict edit A** and blurring Headline installed JSON then failed the XMP mirror.
`baseline-partial-commit.json` records the installed request. The controlled independent-writer
simulation replaced the disposable JSON headline with **Newer saved conflict A**, added
**Independent saved credit**, removed its history witness and removed only the empty XMP blocker.
`baseline-newer-saved.json` records those exact bytes.

Native Close showed the permanent conflict error and retained the workspace. Normal Quit showed
only Retry Save, Keep App Open and Quit Without Saving. No scoped recovery was available.
The coordinator used Quit Without Saving solely to terminate this disposable baseline session,
then confirmed all QA app entries stopped. Newer A JSON remained byte-identical, no A XMP was
created, B/C records were unchanged and every PNG retained its original hash.

This is baseline defect evidence, not a passing recovery test. A fresh final fixture and the
implemented review/export/scoped-discard/native-relaunch path must pass before this slice closes.

## Initial validation plan

The initial plan required source review, focused tests, integrated tests, repository validation
and native recovery; final dispositions are recorded below. A dedicated A15 case was added to the HTML checklist; all human results remain unrun
and no final candidate is assigned. Existing browser visual verification remains pending under
the documented URL-policy restriction.

## First focused checkpoint

Focused v1 built and executed 138 tests in six suites, failing seven export-path cases with
`unsafeExport` in 5.542 seconds (xcodebuild exit 65). The positive fixtures used the macOS `/var`
temporary-directory alias while export intentionally rejects symlink parents. This is being
corrected and reviewed; the result is not a passing gate. The log is
`/private/tmp/aagedal-coordinator-cycle6-focused-v1.log`. Independent review also requested
matching view/review ownership for error and defer callbacks, in addition to successful
async results. Final source and verification will supersede this intermediate checkpoint.

## Implemented recovery contract and review

Each FIFO item retains a stable ID and its complete immutable replay request. Production replay
conflicts now retain a typed failure kind through service, persistence bridge and queue; transient
I/O failures keep Retry Saving. Caption presents a persistent conflict review action outside the
failing durable barrier, including when another photo is selected.

Review captures same-photo committed field buffers before freezing that photo's admission and
queue retries. The snapshot identifies exact canonical full photo URLs including extensions;
same-stem RAW/JPEG and unrelated requests retain their identities and FIFO order. Export contains
all pre-trim changes, baseline/history/presence, captured sidecar and original snapshot, partial
JSON commit receipt, plus explicit technical fields omitted by ordinary editorial JSON.

A Save panel chooses a separate local JSON. A private 0600 staging file is verified, atomically
installed and verified again; protected image/XMP/metadata destinations and symbolic-link parents
are rejected. Discard checks the active review, exact request IDs, per-photo generation, export
bytes and SHA-256 before removing only that exported set. Changed or deleted exports, late
affected requests and failed export retain every queued request. Unaffected work resumes through
the existing FIFO writer; a later transient failure remains visible and retryable.

Reload requires the same photo, folder, load identity and unchanged editor, with no uncaptured
technical edits. Error clearing is bound to the resolved request so it cannot erase a newer or
unrelated error. Delayed queue callbacks recheck the published current failure. All UI async
success/error/cleanup paths now verify operation and workspace lifetime; review state also checks
the review identity. A begin-review result returned after disappearance ends its queue review.
Independent final v2 review found no remaining concrete blocker in this bounded contract.
The UI lifetime paths have source review; core callback delivery has deterministic injection tests.

V2 attempted to canonicalize the fixture with Foundation's `resolvingSymlinksInPath()`, but the
same seven positive export cases still failed: 138 tests / six suites / 6.006 seconds, exit 65,
`/private/tmp/aagedal-coordinator-cycle6-focused-v2.log`. A standalone Foundation reproduction
proved that the actual temporary-directory URL still presents `/var/folders/...` after that call;
traversal encounters `/var` as a symbolic link. Explicit `/private/var` or `/private/tmp` URLs
retain their physical spelling. The next fixture correction must use a proven physical path;
production destination protection remains unchanged. This failed run is not final evidence.

## V3 validation

The validator now walks raw URL ancestors before canonical protected comparisons, so Foundation
does not rewrite physical `/private/var` to logical `/var` during the safety check. Canonical
metadata-folder checks also reject dot-component traversal. Tests use POSIX `realpath` for the
fixture root; real symlink negatives remain. Independent path-only re-review passes.

Focused v3 passes **138 tests in six suites, 5.714 seconds**, xcodebuild exit 0 and TEST SUCCEEDED.
The exact command selects CaptionConflictRecoveryTests, CaptionSessionTests, MetadataReplayIntentTests,
MetadataEditorReadServiceTests, MetadataSidecarServiceTests and
ApplicationTerminationFlushCoordinatorTests from the standard macOS serial test invocation.
Log: `/private/tmp/aagedal-coordinator-cycle6-focused-v3.log`. Full serial regression passes
**2,523 tests in 282 suites, 89.939 seconds**, xcodebuild exit 0 and TEST SUCCEEDED, in
`/private/tmp/aagedal-coordinator-cycle6-full-v3.log`. Final repository validation exits 0 in
`/private/tmp/aagedal-coordinator-cycle6-repository-v3.log`; `git diff --check` passes.
Source was committed as `7a503b3` with no intervening source edits after these tests.

### Native recovery still pending

After the passing integrated run, the coordinator tried to launch the exact Debug app through
computer use. CUA reported **The Mac is locked and automatic unlock could not unlock it**.
The recovery workflow was not exercised; no unit test or prior baseline interaction substitutes
for that gate. No unlock bypass or unrelated process interruption was attempted. Independent
source review, commits, checklist and next-slice preparation continue, so no user escalation
or no-progress count is warranted.

The untouched final fixture is prepared at `build/qa-caption-conflict-cycle6-final/`, with A/B/C
pending JSON, original synthetic PNGs and an empty A XMP blocker. Its initial manifest and
`tested-binary-identity-v3.json` identify the final test baseline. The required next native run
must type actual A/B/C edits, induce the permanent A conflict, cancel review/export without loss,
export and tamper-check, explicitly discard only A, persist actual B/C through the resumed FIFO,
then Close/normal Quit and relaunch. Preserve newer A bytes and all source pixels. The automated
ordering test uses injected B/C callbacks; actual file persistence needs this native proof.

Tested Debug build: **3.0.0 (738), arm64**, macOS 27.0 (26A428), SDK 26.5.
Executable SHA-256: `8f099225003d046f3a8ae579a392bfa32b55d5079c26c113b9d2a7580e78dd04`.
Debug dylib SHA-256: `5430743c93ddbfdfd16c03996b0c107c7713f49285c5e7e4ed9616a79ab3ab6b`.

The checklist passes static validation for **30** complete unique cases (15 agent, six final-user,
nine external/hardware), valid local source links and JavaScript syntax. Candidate fields remain
blank and all human results unrun; browser visual verification is still pending. All 60 current
unchecked authoritative criteria remain open. Automation remains active; release readiness has
not been claimed.

## End-of-cycle disposition

A second native launch recheck after independent commit/document work still reported the Mac
locked. The final recovery fixture was not opened or changed. This is a host constraint with
mandatory UI evidence pending, not a product pass or a total-progress blocker. A separate
read-only source audit produced the [field-write continuation design](field-write-completion-design.md)
for Browser, Face and Metadata Review, including partial acknowledgement, snapshot preservation,
actual failure reporting and non-reentrant lock boundaries. Those callers remain unimplemented.

Implementation `7a503b3` is coherent and locally committed; no source change followed the final
passing checks. Native recovery is the first next gate when access resumes. If access remains
unavailable, continue the independently actionable field-write work without requesting a user
unlock until the protocol's total-progress blocker conditions are met.
