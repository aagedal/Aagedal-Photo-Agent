# Field-only write completion and Metadata Review continuation

Source-backed cycle-6 audit of `7a503b3`, followed by [cycle 7](cycle-07-field-write-completion-2026-09-10.md),
[cycle 8](cycle-08-explicit-label-clear-2026-09-11.md) and [cycle 9](cycle-09-durable-rotation-2026-09-11.md).
Browser rating/label and Face add-person completion are natively verified. Source `b5840e4` adds
durable orientation drafts, expected→target field writes, destination-specific retry baselines,
Write Pending Rotation, display precedence and whole-record/export admission guards. All 2,569
integrated tests pass. [Cycle 10 native verification](cycle-10-rotation-native-2026-09-11.md)
passed history-only rotation, normal quit/relaunch, Write All refusal and explicit dual-write
application, with original preferences restored. [Metadata Review cycle 10](cycle-10-metadata-review-2026-09-11.md) is committed as `f897bdd`,
with retained buffers/shared replay/recovery and 2,585 integrated tests passing. Native edit/exit/quit/relaunch
passes; [cycle 11 native recovery](cycle-11-review-recovery-native-2026-09-11.md) also passes retry, verified export and scoped discard. [Write All cycle 11](cycle-11-write-all-2026-09-11.md) passes 2,602 tests and bounded native failure/repair/relaunch; non-displayed variables remain mandatory work. External empty
element-form Label parsing remains separate from app-written empty attributes. Original
observations below are historical; the old Browser field helper chain now has no entry caller.

## Original caller audit on 7a503b3

- `BrowserViewModel.applyMetadataField` (around line 2108) saves pending=false before embedded
  writes and refreshes status even after write failure. `applyFieldToSidecar` (around line 2189)
  reads outside the merge lock, promotes an existing nil original snapshot through fallback,
  saves a whole record and mirrors XMP in a separate transaction. Dual writes call it twice.
- `saveMetadataReviewEdit` (around line 3077) trims history before generic merge, promotes an
  existing nil snapshot, starts untracked tasks and splits JSON/XMP locks.
- `FaceRecognitionViewModel.applyNameToMetadata` and `applyAllNamesToMetadata` (around lines
  2488 and 2560) also save pending=false before embedded writes. `applyNamesToFile` (around
  line 2706) returns false on failure; callers ignore it and post a completion notification or
  callback. `applyNamesToSidecar` repeats the generic whole-record/pending/snapshot behavior.

Line numbers are hints for this revision; method names identify the source contracts.
Cycle-5 `completeSidecarAndMirrorXMP` acknowledges a complete record and must not be reused to
acknowledge only rating or names: that could incorrectly complete an unrelated pending caption.

## Bounded field mutation service

Introduce an immutable per-photo request with stable ID, captured photo/folder/write mode and
explicit mutation: rating, label, orientation (expected/new), or add-person names. Prepare under
the existing photo lock by strictly loading owned JSON and relevant destination facts, applying
only that mutation to the latest draft, and retaining raw JSON/XMP tokens and field baselines.
Preserve existing nil original snapshots and unrelated fields/history.

Write only the requested fields to physical destinations. Complete under exact captured CAS,
acknowledging only field values actually written. Update only those values in a known original
image snapshot and recompute remaining pending differences. With a nil snapshot, retain pending
unless complete-record evidence independently proves that all draft intent is saved. An unchanged
JSON field must not skip a necessary physical destination write or repair.

Face append needs each physical destination's own current list: preserve source-only names and
avoid accidentally applying unrelated queued additions/removals just because draft JSON contains
them. The completion baseline records the actual written personShown list.

Prepare JSON intent and tokens under one lock, release before calling the embedded write engine
(which acquires its own coordinator), and reacquire for completion. Never recursively acquire
that same coordinator. XMP-only mutation/acknowledgement can use a held-lock helper in one
transaction. After embedded write, dual-write mirroring must first verify the captured JSON/XMP
baseline. Failure or newer data preserves pending intent and reports which physical writes
already occurred. Return immutable per-photo destination, draft, pending, conflict/failure and
cancellation results; stale selection/tasks cannot publish obsolete UI success.

## Separate Metadata Review migration

Use explicit `MetadataSidecarReplayRequest`, complete pre-trim changes, baseline metadata/history/
presence and retained receipt. Serialize each photo's retained request/result sequence and JSON/XMP
mirror; remove bare untracked write tasks. A permanent conflict needs visible recovery, never
silent replay or overwrite. This draft flow is distinct from field-only physical acknowledgement.

Cycle 9 supplies the explicit technical treatment: `IPTCMetadata` Codable still omits orientation,
while `MetadataSidecar.orientationDraft` durably carries the intent. Ordinary Caption saves preserve
it; only verified field completion removes it. Whole-record writes and exports direct the user to
apply the pending rotation first. Cycle 10 verifies history-only persistence and dual-write
application natively; XMP-only and injected partial-failure rotation cases retain automated
evidence only. See the cycle-10 native report for the exact tested binary and remaining scope.

## Required tests and integration order

Inject destination writers/read facts and deterministic pauses before and after physical commit.
Cover unrelated pending caption + rating/name write; existing nil snapshot; embedded/XMP failure;
newer same/disjoint draft; Face writer false reaching result/UI; source-only person names and
pending removals; no-delta physical repair; rapid actions/folder changes; RAW/C2PA routes;
orientation persistence; and more than 20 Metadata Review fields with partial-mirror retry.
Run actual Browser and Face workflows on disposable fixtures, read back all destinations and
pending markers, then relaunch. Injected callback order alone is not actual file-write evidence.

Suggested ownership: service and service tests; bounded Browser callers/tests; bounded Face
callers/tests. Agree APIs before edits, serialize builds/desktop under coordinator ownership,
and obtain independent final review after source integration. Metadata batch completion and
non-displayed variable writes remain subsequent inventoried work.

## Cycle 11 complete-record Write All migration

The legacy batch writer could delete pending JSON after a Void writer silently skipped RAW,
and could leave a stale XMP shadow. The replacement captures immutable owned records and fresh
source/credential facts, uses strict discovery, and routes RAW to XMP. Ordinary formats use a
verified embedded writer and mirror an existing XMP. Only full editorial read-back plus unchanged
source/carrier ownership can mark the original JSON record complete. History, opaque JSON and an
explicit nil original snapshot remain retained. Physical writes that precede failure are reported;
cancellation retains the attempted prefix and identifies the unattempted suffix. Batch-specific
attention remains accessible after selection changes. Independent review, focused/integrated checks and bounded native failure/repair/relaunch pass
on `8fd931c`; see the cycle-11 report for exact scope and remaining real RAW/cancellation gates.

The variable writer remains a separate mandatory slice: capture photo/folder/mode before awaits;
retain full pre-trim changes with stable replay IDs; preserve an explicitly nil original; avoid
acknowledging the complete pending record after writing only variable differences; and propagate
partial/failure/cancellation results. Its displayed-selection branch must await the actual commit
before counting success. Reuse complete-record completion only when every pending editorial value
is physically written and verified, otherwise acknowledge only the field delta actually written.

### Next variable slice: bounded ownership and semantics

Treat Variables in a physical write mode as completion of the full resolved editorial record,
consistent with its existing selected-image/full-XMP intent. First install a verified pending
resolved request, then call an extracted mode-aware complete-record service against that receipt.
Keep Write All's explicit default routing unchanged. History Only needs awaited JSON-only replay;
using the existing JSON-plus-XMP replay would change its contract. A verified pending receipt is
required before counting a history-only save. Preserve unrelated technical Develop/orientation
intent; unresolved technical changes must not be silently completed.

Capture folder, ordered photo URLs/sequence numbers, reference policy, initials/job-ID option,
editor/load identity, batch generation and effective C2PA/RAW write policies before awaiting work.
Fresh per-photo facts select from those captured policies. Resolve an immutable local record for
both selected and nonselected images, taking its original input before GPS/roster transformation.
Remove the selected-image fire-and-forget commit branch. Retain full pre-trim deltas and stable
request IDs across partial retry; do not interpolate again against changed inputs. Preserve an
existing original snapshot by record presence, including nil. Report unreadable individual inputs
and cancelled/unattempted suffixes. Batch attention is separate from selected-editor state.

Suggested ownership: core service owner for JSON-only replay/prepare plus mode-aware verified
completion and service regressions; caller owner for immutable variable requests/runner and model
integration; coordinator for UI barriers, project registration, builds and native QA. Freeze source
during integrated checks and native validation. Existing non-Write-All technical callers still
use parsed cameraRaw equality and may share the random mask-identity issue exposed in cycle 11;
inventory that behavior rather than silently treating this bounded fix as universal.

### Cycle 12 read-only findings and bounded retry lifetime

The independent audit identified three remaining mask-equality callers in MetadataViewModel:
`writeXMPSidecarAndPreserveHistory` (ordinary XMP and Develop primary save),
`writeMetadataAndPreserveHistory` (embedded/dual and Develop reset with embedded CRS), and
single-photo `saveToSidecar` (History Only/explicit pending save). All compare separately parsed
cameraRaw values, whose mask IDs regenerate. These paths can reject an unchanged masked XMP.
The next correction must retain exact XMP bytes with the loaded editor baseline and update them
from verified receipts; capturing new bytes only when Save is clicked would adopt external changes.
Keep technical intent flags and explicit absent snapshots. This is mandatory subsequent defect work.

Variable retry is bounded to the current model/session unless a durable operation carrier is
implemented. A verified pending JSON record preserves the resolved editorial values and history
across relaunch, but does not encode captured write mode/policy, full retry receipt or physical
baseline. Failure details must explain that Retry Variable Writes preserves the original operation
only in this session. After relaunch the user can review pending drafts and deliberately choose a
new physical write operation; Write All is not a resume of the original variable policy. Do not
count a no-placeholder rerun as repair or automatically adopt a new policy. Uncommitted live
buffers still need the existing pending-save/recovery safeguards; this limitation does not permit
losing edits that have not reached verified JSON.


### Variable permanent-conflict recovery implementation outline

Independent cycle-12 review recommends photo-scoped review/export/discard, following Caption's
verified private export pattern. Replace opaque pre-prepare admission ownership with an exportable
captured payload plus executor: original live/template fields, sequence, frozen options, ownership
checkpoint and optional cached first-read facts. Failed reads must export without rereading.
Expose a lock-protected request/receipt snapshot with full pre-trim deltas, explicit known/null
originals, technical metadata (ordinary IPTC JSON omits it), preparation and partial physical evidence.

Freeze affected-photo capture/retry before reviewing; settle in-flight work before snapshotting.
Bind verified export receipts to exact bytes, request/admission IDs, generation and review ID.
Canonical full photo identity includes the extension, preserving same-stem RAW/JPEG siblings.
Revalidate export and generation immediately before scoped in-memory discard; never modify image,
JSON or XMP during discard. Other folders/photos keep their requests and retry order. Preserve newer
live editor input; reload only an unchanged original checkpoint. Reconciliation creates a new request
from fresh facts rather than rebasing stale intent. Cancel or failed/tampered export removes nothing.

Tests must cover pre-prepare unsaved input after selection changes, >20 changes and all receipt
fields, same-stem siblings/other folders, late completion or stale generation, changed editor input,
and native conflict/export/scoped discard/remaining-work/Close/Quit/relaunch with exact file hashes.
This is an implementation outline, not completed recovery or passing acceptance evidence.
