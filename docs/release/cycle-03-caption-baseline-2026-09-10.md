# Coordinator cycle 3 — pending Caption baseline preservation

**Date:** 2026-09-10 Europe/Oslo.
**Baseline:** `ef0250721a8534368ddfdef0815c1408f43f0220` (the tested memo Trash slice).
**State:** committed; independent source review, integrated tests and bounded native checks passed.
**Implementation commit:** `914e99621ccd13e04df537bd903ed6d22ad4d01e`.

## Observed defect and bounded correction

Native testing of the restored synthetic Trash bundle found that opening and closing an
untouched pending Caption draft later changed its JSON timestamp and original snapshot to
the pending caption. Finder recovery itself had preserved the JSON byte-for-byte. Source
inspection confirmed that a loaded pending record sets `hasChanges`, which was also the
automatic-save condition. Saving mirrored pending metadata into XMP allowed a later read
to use that pending text as the next snapshot. The exact intervening native reload was not
instrumented; the reproduced file mutation and source path support this diagnosis.

The view model now distinguishes pending metadata from edits made since the last capture.
Automatic Caption capture and focus-leave persistence skip unchanged drafts. Actual edits
preserve the identity-matched pending record's original snapshot, including an explicitly
absent snapshot in legacy JSON. Display/reference metadata remains separate. Pending field
names compare against the saved baseline when available. Explicit Write stays available,
and the FIFO queue still drains failed requests when a later capture returns no new work.

One sub-agent owned the view model, panel and regression cases; a separate source reviewer
reported no blocking finding in this bounded change. The coordinator owns builds and UI.
Six parameterized regression cases cover untouched JSON/XMP bytes, real edits, source
switches/reloads, missing legacy snapshots, explicit Write and failed FIFO retry.

The first focused build caught two missing inner `try` annotations in throwing test macros;
they were corrected. The second attempt exposed a real deadlock in the unchanged failed-FIFO
regression. A process sample showed synchronous `flush` → `queue.sync` retry executing inline
on the MainActor task, then waiting in `CaptionDraftPersistence.persist` for its async work.
An initial detached-task-only correction did not resolve the hang. Further source review
found `MetadataIOKey.key` implicitly isolated to MainActor; the surrounding awaited actor call
hid that dependency. The stateless URL-derived key helper is now explicitly nonisolated, and
the bridge uses an independent detached task. Serialized persistence and the synchronous
completion contract remain. The regression still exercises synchronous exit;
it was not changed to avoid the failing path. Only the coordinator's stalled test run was
interrupted. Evidence: `/private/tmp/aagedal-coordinator-cycle3-caption-focused-v2.log` and
`/private/tmp/aagedal-cycle3-caption-retry-sample.txt`. This executed-test defect is separate
from the historical prelaunch XCTest handshake failure in the Trash slice.

## Native verification fixtures

`build/qa-caption-baseline-cycle3/` contains two copies of the generated 640×400 PNG,
`unmirrored.png` and `mirrored.png`. Both app JSON records have pending text
`Pending baseline preservation caption`, an empty original description, empty history,
no color label and a fixed timestamp. Only `mirrored.png` initially has XMP containing the
pending text. `fixture-manifest.json` records all five original hashes. These are synthetic
local fixtures; no private photo metadata is involved.

## Final validation and native observations

The attempt to select one Swift test by function name selected zero tests and is not counted
as verification (`/private/tmp/aagedal-coordinator-cycle3-caption-retry-v4.log`). Selecting
whole suites then passed **111 tests in seven suites, 1.579 seconds**, including the unchanged
failed-FIFO regression in 0.052 seconds
(`/private/tmp/aagedal-coordinator-cycle3-caption-focused-v5.log`). The final unfiltered run
passed **2,449 tests in 278 suites, 109.686 seconds**
(`/private/tmp/aagedal-coordinator-cycle3-caption-full.log`). Both successful runs report
`TEST SUCCEEDED`. Repository checks passed
(`/private/tmp/aagedal-coordinator-cycle3-caption-repository.log`), as did whitespace checks.
No later source change invalidated these results. The independent reviewer found no blocking
issue in the final persistence bridge and key helper.

The coordinator launched the tested **3.0.0 (738), arm64 Debug app** through native CUA on
macOS 27.0 (26A428), built with SDK 26.5. Bundle:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
This is a development build, not a final packaged candidate. SHA-256:

- `Contents/MacOS/Aagedal Photo Agent`: `6d0c509f5bdabb5b0ed68b20e0f5fbe7638c0ba7be32b5e5e9acad7c97dbab8c`
- `Contents/MacOS/Aagedal Photo Agent.debug.dylib`: `d386dc2464915335af44fe59dfdb7bde3829fe0b6bfd3ea060fa82ebc1737884`

Observed native steps and filesystem read-back:

1. Opened the fixture folder, selected `unmirrored.png`, entered Caption, focused Description
   then Headline without typing, navigated to `mirrored.png`, repeated focus changes, closed
   Caption and quit normally. Both pending captions displayed correctly. All five original
   hashes remained exact, including JSON timestamps/snapshots; `unmirrored.xmp` stayed absent.
   Native inventory confirmed termination completed.
2. Relaunched and reopened the same folder. In Caption on `unmirrored.png`, typed
   `Explicit baseline test headline`, left the field and selected the other photo. JSON now
   contains that headline, the original pending description and exactly one Headline history
   entry. Its original snapshot still has no description or headline. XMP was created only
   after the real edit. Both PNGs and every mirrored fixture file remained byte-exact.
3. Selected the edited photo again: the headline and pending caption reloaded correctly.
   Quit normally. All six photo/sidecar hashes matched the saved `after-edit-manifest.json`;
   reload/quit added no extra write. The explicit new edit was checked after selection reload
   and quit, not a further full process relaunch. Automated tests cover repeated model reload.

The screenshot and AX inspection also found a narrower UI discrepancy: the workspace remains
Pending, but field-level pending markers disappear when XMP already mirrors the draft.
`pendingFieldNames` is corrected; individual field comparisons still use the current reference.
Include them with the explicit Restore/history reference correction below. This is not a claim
that all pending-state presentation is fixed. Failed-write retry was proven by the real
persistence regression; a native filesystem-failure injection was not performed here.

The HTML retains 29 unique complete draft cases and passes source-link/JavaScript syntax checks.
Independent document review confirmed all 61 verbatim baseline gate blocks remain intact.
Browser visual/interactive checklist validation and exact-candidate binding remain pending.

## Remaining boundary

Explicit Restore and history replay still derive their targets from the currently selected
embedded/XMP reference. With original snapshot A and mirrored pending XMP B, that reference
can already contain B. This pre-existing behavior needs a separate test of repeated Restore,
history replay and reload, including the intended JSON/XMP write-mode semantics. This slice
does not claim to fix restoration. Ordinary save/migration/clear shared-legacy ownership
also remains open. These findings stay in the coordinator's ordered work rather than being
silently accepted as final user testing.
