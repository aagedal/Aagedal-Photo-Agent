# Scoped Caption queue conflict recovery

Proposed by independent cycle-5 review; implemented in `7a503b3` with independent review and
passing automated checks. **Native recovery validation passes** on the same source, as recorded in
[cycle 7](cycle-07-field-write-completion-2026-09-10.md). [Cycle 6](cycle-06-caption-conflict-recovery-2026-09-10.md)
retains the original automated results and temporary host-access limitation. The criteria below remain the contract
and include the required native gate. Permanent replay conflicts preserve newer disk data but retain
an immutable FIFO head, blocking durable actions. Quit Without Saving can abandon all queued
work; a scoped recovery path must preserve unrelated edits.

## Queue and persistence contract

Give each queued Caption item a stable request ID and retained typed request in
`CaptionSession.swift`. Distinguish a permanent typed replay conflict from transient I/O failure
and expose an observable conflict record through the flush coordinator. Keep generic operation
injection for tests. Retain the complete captured sidecar, pre-trim changes, baseline metadata
and history, baseline-presence flag, and JSON-commit receipt state for recovery export.

Scope affected requests by canonical photo URL **including its extension**, not the shared-stem
metadata lock key. Snapshot the failed request and all dependent queued requests for that exact
photo. RAW/JPEG siblings and other photos retain their requests and relative FIFO order.

## Review, export and explicit discard

Expose Review queued conflict in Caption outside the normal flush barrier. Show the photo,
conflict reason, affected request count and the assurance that newer saved files will be kept.
Provide transient Retry, Export conflict, and an explicit Discard exported queued edits and
reload action. Freeze admission for the affected photo during review; retain other photos' work.
Do not automatically rebase onto or overwrite newer metadata.

Export through a local Save panel. Atomically save and verify the complete recovery JSON before
enabling discard. Bind the export receipt to its byte hash, exact request IDs and queue generation.
Recheck that set when discarding; any new affected request invalidates the receipt and requires
a refreshed export. Cancelled or failed export removes nothing. Keep the export private/local.

After explicit discard, remove only the verified exported set, clear its failure, and resume
unaffected FIFO work. Never change or delete the source image, current metadata JSON or XMP.
Reload only if the current selection is still the reviewed photo. Ignore obsolete failure callbacks
by request ID/generation. Keep broad Quit Without Saving visibly separate from scoped recovery.

## Required validation

- Permanent conflict A blocks normal drain; B/C remain queued. Export and explicitly discard A,
  then persist B/C in order with their full edits.
- Same-photo dependencies are exported/discarded together; a same-stem other-extension photo
  survives. Export retains more than 20 fields, optional original snapshots and partial-commit state.
- Cancelled/unwritable export, verification mismatch or stale generation removes nothing and
  changes no source/JSON/XMP bytes.
- Late failure callbacks cannot re-block resolved UI; reload/selection changes cannot discard
  newly typed edits. Later transient failure remains retryable after recovering A.
- Native error → review → export → explicit discard → Close and normal Quit succeeds without
  Quit Without Saving. Relaunch verifies newer A and unaffected B/C. Record export integrity,
  exact tested source and fixture hashes. Unit tests alone do not close this interaction gate.
