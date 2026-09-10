# Coordinator cycle 5 — Caption retry and write-completion intent

**Started:** 2026-09-10 11:02 UTC.  
**Baseline:** clean `ea63df4` on `main`; implementation `43ddf32` passed 2,479 tests / 280 suites.  
**State:** bounded Caption integrity slice implemented, independently reviewed and validated. Release remains IMPLEMENTING.  
**Implementation:** `42ace70ce67086bce6c5191697b5b8f329d57f65`.

The coordinator reread the protocol/readiness and reconciled the five authoritative plans.
Their 61 baseline open criteria remain unchanged. The active task inventory shows FTP Sync
working in its separate repository; no other task edits this checkout. The coordinator owns
native UI, builds and integration. Service and caller changes are delegated with explicit file
ownership and an agreed API; an independent reviewer audits the contracts and final diff.

The highest-priority defect is an already-applied Caption FIFO retry replacing a newer current
record when it has no new history event. It can erase another writer's independent metadata,
original snapshot or pending status. Generic no-history saves also legitimately represent
technical updates or successful Write completion, so a blanket keep-current merge is unsafe.
This slice introduces explicit intent and guards successful Write completion against newer edits.

`build/qa-caption-retry-cycle5-baseline/` uses the earlier generated 640×400 synthetic PNG and
an initial headline A record. An empty directory named `retry.xmp` intentionally prevents the
XMP mirror from being installed while allowing the JSON half to persist. Its initial manifest
identifies all original files. Only these disposable fixtures are modified during fault injection.


## Native baseline reproduction

Using the unchanged cycle-4 Debug build, the coordinator opened the synthetic folder and
selected `retry.png`, whose pending headline A was displayed in Caption. Replacing it with
`Captured headline B` and focusing Description produced the alert **Failed to save sidecar:
The file “retry.xmp” couldn’t be opened**. Read-back showed JSON B and its exact A → B event
already installed, while the intentionally obstructing XMP directory remained. The app kept
its editor B and an error. `after-failed-mirror.json` records this checkpoint.

A controlled external-writer simulation added `Independent credit C` and `Newer headline C`
with new history identities to that disposable JSON, then removed only the empty XMP blocker
directory. `intervening-writer.json` records the durable intervening values. After dismissing
the alert and closing Caption (durable barrier), JSON retained credit C but **replaced newer
headline C with stale B**, adding a second A → B history event with a different UUID. No typing
occurred after the intervening update. The image bytes stayed exact. `after-stale-retry.json`
records the outcome. This native failure is a related actual entry-path defect, not proof that
the no-new-event branch itself ran: Caption field blur/debounce calls the generic
`saveToSidecar()` path, which failed after JSON commit without advancing the model's prior edit;
the later FIFO capture manufactured another event. The correction must route Caption blur
through its FIFO too. The older generic no-new-event erasure still requires its dedicated
service regression. The baseline QA app was quit after collecting evidence.

## Implementation and independent review

Caption field blur/debounce now captures the same immutable FIFO request as navigation. Each
request carries its baseline, whether that baseline record existed, complete field changes
before the visible 20-event history limit, and a shared commit receipt. A retained exact event
payload proves an operation was already applied: its retry keeps the current JSON bytes and
mirrors current metadata under the same photo lock. Missing ancestry, overlapping uncommitted
changes, discarded records and ambiguous trimmed history fail closed. The receipt records JSON
installation before read-back so a failed verification cannot authorize resurrection later.

Single-photo explicit XMP, embedded Write and technical pending saves capture the expected JSON
record and editor technical baseline before writing. Completion validates current JSON and XMP
revisions, mirrors first, then checks the exact installed XMP bytes before finalizing JSON. An
embedded write which already happened is reported accurately when its later completion conflicts;
newer pending data remains. Selection/edit generations keep late callbacks from changing another
editor. Normalized written XMP supplies the next technical baseline, while untouched Develop and
orientation values and unmodeled legacy localized titles are preserved. Explicit Restore retains
its separate exact-target semantics. Generic whole-record callers are not silently changed.

The independent reviewer found and the owners corrected legacy nil localized-title deletion,
post-mirror external XMP replacement, pre-admission technical changes and first-attempt deletion
of an empty-history baseline. Final read-only review found no further defect within this bounded
preservation scope. It explicitly retained the conflict-recovery and adjacent-writer work below.

## Automated verification

The first focused run executed 142 tests in eight suites and failed one new template fixture.
It assigned the invalid raw country code `Value 16`; replay correctly normalized the country
field and refused a payload that no longer matched the captured record. The fixture is corrected
to a valid ISO country code, keeping the strict replay guard. The same review identified a mixed
Caption/technical buffer boundary: editorial capture must not advance the unpersisted Develop
or orientation baseline. Its correction and regression require a fresh focused build. The first
run is diagnostic evidence only (`/private/tmp/aagedal-coordinator-cycle5-focused.log`), since
the subsequent VM correction arrived after that VM's compilation.

The corrected frozen source passes **143 tests in eight suites, 4.541 seconds**, with
`TEST SUCCEEDED` (`/private/tmp/aagedal-coordinator-cycle5-focused-v2.log`). The command used
the protocol's Xcode test invocation with one `-only-testing:'Aagedal Photo Agent Tests/SuiteName'`
argument for `MetadataReplayIntentTests`, `MetadataEditorReadServiceTests`, `MetadataHistoryTests`,
`MetadataSidecarServiceTests`, `MetadataCarrierOwnershipTests`, `MetadataAutomaticSaveBoundaryTests`,
`CaptionSessionTests` and `ApplicationTerminationFlushCoordinatorTests`. Narrow independent
re-review of the mixed-buffer correction and fixture also passed. Integrated/native validation follows.

The v2 integrated run passes **2,503 tests in 281 suites, 86.386 seconds**, with `TEST SUCCEEDED`
(`/private/tmp/aagedal-coordinator-cycle5-full.log`); repository validation also passes
(`/private/tmp/aagedal-coordinator-cycle5-repository.log`). Native testing then found an actual
Caption Write cleanup-entry mismatch, described below. Its correction invalidates v2 as the final
integrated source and requires fresh focused/full validation.

## Native v2 retry and actual Write entry

The coordinator launched the full-suite Debug binary, version 3.0.0 (738), arm64, macOS 27.0,
from the project's DerivedData `Build/Products/Debug/Aagedal Photo Agent.app`. The final synthetic
fixture folder is `build/qa-caption-retry-cycle5-final/`. Opening `retry.png` in Caption displayed
Initial headline A. Typing Captured headline B and focusing Description produced an actionable
ownership error for the intentionally obstructing `retry.xmp` directory. JSON B and one exact
event were already durable. A controlled external writer added newer headline C and credit C,
then the coordinator removed only the empty blocker and closed Caption.

This retry **passed**: JSON remained byte-identical to the intervening writer's record, with
three events, pending=true and original snapshot A; XMP mirrored newer C and credit C. Both PNGs
retained their initial hashes. Normal quit, relaunch, folder reopening and Caption selection
displayed newer C and preserved all four source/sidecar hashes. Evidence files are
`after-failed-mirror.json`, `intervening-writer.json`, `after-durable-retry.json`,
`before-relaunch-manifest.json` and `after-relaunch-manifest.json`.

Write & Next on the reloaded C advanced to `z-next.png`, embedded C and credit C in PNG XMP,
and intentionally removed the JSON through Caption's existing `writeMetadataAndClearSidecar`
entry. The PNG's IHDR/IDAT chunks remained exact. This observes the cleanup path, not the new
preserve-history completion API. `after-write-manifest.json` records that checkpoint.

The coordinator then returned to the photo, entered Immediate headline E, verified the editor
value, and blurred Description. JSON E and its single C → E event persisted. Clicking the
fresh Write & Next control produced **Metadata was written, but newer pending sidecar changes
were retained**, although no independent writer had intervened. The image contained E while
JSON E remained pending. `after-false-cleanup-conflict.json` records this false conflict. The
actual Caption cleanup method still supplied its older loaded `cleanupBaseline`, rather than
the current durable FIFO expectation. The correction uses that captured expectation and aligns
late completion generation guards. New regressions invoke this actual method, not only
`commitEditsReportingResult`, and check both successful deletion and retention of a newer draft
arriving while the image writer runs. The QA app was quit normally and inventory confirmed it
stopped before rebuilding.

Focused v3 passed **145 tests in eight suites, 5.987 seconds**
(`/private/tmp/aagedal-coordinator-cycle5-focused-v3.log`). Independent review then found that
Write & Next still advanced on a nil error even when a newer same-photo editor buffer prevented
the VM from accepting the completed write. The final navigation gate must require that the
editor has no remaining pending or unsaved changes; a held-write regression covers preservation
of a newer in-memory edit. No v3 full run was repeated before making that correction.

The navigation correction also distinguishes two newer-edit states. A captured request which
has not yet persisted still depends on the saved JSON ancestor, so a later capture generation
prevents cleanup from deleting it, including after selection changes. An uncaptured editor
buffer survives a completed cleanup and receives the written metadata as its next baseline.
A short cleanup phase blocks new capture before optimistic state changes and lets a requested
same-photo reload wait for deletion to finish. Cleanup owners release waiters on completion or
cancellation. The final navigation turn checks photo identity and committed IME composition,
captures remaining AppKit text, and refuses to advance while any pending or unsaved edit remains.
Capture generations identify complete canonical image paths, including extensions; only the short
cleanup phase conservatively shares the XMP stem lock key. Tests cover reload before cleanup
admission and delayed/new editor captures. The admitted-phase continuation wait and real IME
interaction have source review, not a separately injected runtime test or native IME proof.

V4 focused validation passed **161 tests in nine suites, 6.620 seconds**, adding
`CaptionWorkspaceSpeedToolsTests` to the preceding focused command. Full regression passed
**2,508 tests in 281 suites, 87.034 seconds**; repository validation passed. Logs are
`/private/tmp/aagedal-coordinator-cycle5-focused-v4.log`, `-full-v4.log` and `-repository-v4.log`
with the same `aagedal-coordinator-cycle5` prefix. These are historical checkpoints because
the native direct-write test then found another entry-buffer defect.

### Native active Headline buffer failure

The coordinator loaded the retained E draft in the v4 binary, typed **Final immediate headline F**
and verified that exact value in a fresh accessibility snapshot while the Headline field remained
focused. Clicking the freshly located Write & Next without a separate blur advanced to the next
photo and removed JSON, but both PNG XMP and the companion XMP still contained E. F was lost.
`after-unflushed-headline-v4.json` records the observed editor value and resulting artifact hashes.

`EditableTextField` buffers every scalar field locally until focus loss, whereas the common
`flushBufferedFields()` only captured Description and Extended Description from AppKit. Clicking
the bottom action did not end the Headline field's focus, so both pre-write and post-write barriers
missed F. The correction must synchronously capture the active scalar field too, preserving field
normalization and IME rules and avoiding implicit adoption of repeatable-list input. Native direct
Write must pass before this slice is complete. The app was quit and inventory confirmed it stopped.

The buffer correction registers each scalar/multiline field's own local state with an owner
token and live photo-load identity. It covers the 19 actual focus keys, preserves the bindings'
empty-to-nil/whitespace behavior, and excludes repeatable query, structured and picker inputs.
Both registry capture and direct blur callbacks reject marked text and stale load ownership.
Newer programmatic model changes take precedence before SwiftUI's delayed synchronization;
QuickList updates its local buffer before committing. Capture uses a local metadata copy to
avoid overlapping access through the backing Binding. Independent review found no remaining
concrete blocker in this narrow change. Regressions invoke owned title-buffer capture, FIFO
persistence and the actual cleanup writer, asserting F reaches its fields and XMP.

## Final v5 validation

The committed source passes **165 focused tests in nine suites, 6.576 seconds**, and
**2,512 integrated tests in 281 suites, 88.825 seconds**. Both xcodebuild commands exited 0
with TEST SUCCEEDED. Repository validation and `git diff --check` pass. Final logs are
`/private/tmp/aagedal-coordinator-cycle5-focused-v5.log`,
`/private/tmp/aagedal-coordinator-cycle5-full-v5.log` and
`/private/tmp/aagedal-coordinator-cycle5-repository-v5.log`.

Native testing then reproduced the precise v4 interaction on the v5 build. The coordinator
opened the synthetic final folder with embedded Headline E, typed **Final immediate headline F**,
confirmed F and active Headline focus in fresh accessibility state, and clicked the freshly
located Write & Next without Return or a separate blur. The app advanced to `z-next.png`.
Both embedded PNG XMP and companion XMP now contained F and preserved `Independent credit C`;
the owned JSON was removed successfully. Returning to the first photo displayed F.

The same direct interaction with Description wrote **Final direct description V5**, advanced,
and preserved F and credit C in both destinations. PNG IHDR and IDAT payloads match the original
synthetic image. The next photo is byte-identical to its original, with no JSON or XMP created.
Normal quit, confirmed stopped inventory, relaunch, folder reopen and Caption selection displayed
both final values. Every tracked artifact hash remained identical across relaunch. A final normal
quit and native inventory confirmed all QA app entries stopped.

Final synthetic artifacts in `build/qa-caption-retry-cycle5-final/`:

| Artifact | SHA-256 / state |
| --- | --- |
| `retry.png` | `c2970bb258aea59f7967b200347fd10cab29c6b59a5fed527eb1855b5954f4b6` |
| `retry.xmp` | `59c708d524f4d8c3caffccec44d7300883f0f9409e9ac56504e7a4750b4f0fe0` |
| `z-next.png` | `0085b9606833f3f836b46901d34f57b70eef92ca95e840f75e655ccffb123037` |
| `.photo_metadata/retry.png.meta.json` | Absent after successful explicit Write cleanup |

`after-unflushed-headline-v5.json`, `before-relaunch-manifest-v5.json`,
`after-relaunch-manifest-v5.json` and `tested-binary-identity-v5.json` retain local evidence.
The tested Debug app is **3.0.0 (738), arm64**, on macOS 27.0 build 26A428, SDK 26.5.
Its executable SHA-256 is `da65f86c1bd31b5dbe1c8c932a8a3abffd9cadff25e75871c195d39e69072221`;
debug dylib SHA-256 is `4688543845930588947e3917a49a469368b4638fd09dba3f65161c325144ecc4`.
No source changes followed the final tests/native run before the implementation commit.

The HTML checklist now includes active-field direct Write and partial-mirror/newer-writer retry
steps. Static verification covers 29 complete unique cases, source links and JavaScript syntax;
its candidate remains blank and human results unrun. Browser visual verification remains pending
under the previously documented local-file URL policy restriction.

This is narrow integrity evidence, not final readiness. Scoped permanent FIFO conflict recovery,
adjacent writers and all broader open gates below remain mandatory. The 61 baseline open criteria,
audit 66/75 and investigation delivery 119/142 remain unchanged. Automation stays active with
zero consecutive runs lacking possible progress; no user notification is warranted.

## Scope of adjacent write-completion risks

Independent review also cataloged nearby pre-existing paths which remain outside this bounded
Caption/single-photo completion change and must be handled in the next integrity slice:

- A permanent Caption replay conflict retains its immutable FIFO head. Previous/Next can still
  enqueue, but Write, templates, Copy Previous, code replacement, Close and normal durable
  termination drain that head and cannot succeed. The existing Quit Without Saving escape
  can abandon all queued work, including unrelated edits; it is not scoped reconciliation.
  Reload alone cannot repair or remove the captured request.
  Add explicit review/export or discard of the failed request and its dependent queued edits,
  scoped to their photo and preserving newer disk bytes. Never silently drop the queue or weaken
  the conflict guard. This newly exposed recovery limitation is the first next action.
  The [scoped recovery design](caption-conflict-recovery-design.md) records concrete queue,
  export, discard, callback and native acceptance requirements; it is not an implementation claim.

- Browser rating/label/rotation `applyMetadataField` → `applyFieldToSidecar` saves a mode-derived
  pending=false record before its embedded write; failure or unrelated pending captions can be
  misrepresented. Metadata Review also uses generic replay plus a separate XMP lock.
- Face `applyNameToMetadata` / `applyAllNamesToMetadata` saves pending=false before the embedded
  person-name write and ignores the latter's Bool failure.
- Metadata batch XMP completion calls `saveBatchSidecars` after a writer that catches individual
  failures, and clears shared UI pending state; each photo needs an independent guarded outcome.
- `writeResolvedVariables` for non-displayed photos has generic pending=false completion without
  a captured expected record. Displayed-photo routing shares the current single-photo fix.

Tests must cover failed embedded writes, unrelated pending drafts, per-photo partial failures
and newer edits between destination write and JSON completion. These remain release integrity
work, not final-user acceptance exceptions. No claim is made that a new intent API alone fixes
callers which have not migrated to it.
