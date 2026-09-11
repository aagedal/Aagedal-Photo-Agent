# Field-only write completion and Metadata Review continuation

Source-backed cycle-6 audit of `7a503b3`, followed by [cycle 7](cycle-07-field-write-completion-2026-09-10.md),
[cycle 8](cycle-08-explicit-label-clear-2026-09-11.md) and [cycle 9](cycle-09-durable-rotation-2026-09-11.md).
Browser rating/label and Face add-person completion are natively verified. Source `b5840e4` adds
durable orientation drafts, expected→target field writes, destination-specific retry baselines,
Write Pending Rotation, display precedence and whole-record/export admission guards. All 2,569
integrated tests pass; native rotation setup stopped at a host lock before any rotation. Metadata
Review, batch completion and non-displayed variables remain mandatory work. External empty
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
apply the pending rotation first. Native verification remains open; see the cycle-9 report.

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
