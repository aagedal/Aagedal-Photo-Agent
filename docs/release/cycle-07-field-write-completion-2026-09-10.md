# Coordinator cycle 7 — native Caption recovery and field-write completion

**Started:** 2026-09-10 13:23 UTC.
**Baseline:** clean `53d0ef8` on `main`; implementation `7a503b3` passed 2,523 tests / 282 suites.
**State:** IMPLEMENTING. Source `34a7313` passes final automated checks; native Browser and old-build recovery pass. Final native Face retest awaits desktop access.

## Reconciliation and ownership

Protocol, readiness, planning index and the four authoritative plans were reconciled. There are
still 60 current unchecked criteria (9 audit, 23 investigation, 22 journalistic, 6 solar), against
61 historically unchecked baseline entries. No broad criterion is closed by these bounded fixes.
Active FTP Sync and Media Player tasks use separate repositories; this checkout began clean.

Desktop access resumed on the first cycle-7 recheck. The coordinator tested the unchanged
`7a503b3` binary before any new build. Service and caller agents independently implement bounded
rating/label/add-person completion, with a read-only reviewer. Browser rotation, Metadata Review,
batch completion and non-displayed variables remain separate mandatory follow-ups. The coordinator
owns GUI, builds, test registration and commits. No production transfers or publication occur.

## Native scoped Caption recovery — PASS on 7a503b3

The prepared `build/qa-caption-conflict-cycle6-final/` folder contains three copies of the existing
640×400 synthetic PNG with initial pending JSON. The exact Debug binary was 3.0.0 (738), arm64,
macOS 27.0 (26A428), SDK 26.5. Its executable and debug-dylib hashes match the cycle-6
`tested-binary-identity-v3.json` before and after this native session. Source edits for the next
slice were not built or used in these observations.

1. Typed **Queued conflict edit A** in Headline and blurred it. The JSON edit and one exact
   history event persisted, while an empty directory at `a-conflict.xmp` prevented the mirror.
   `partial-commit.json` preserves the actual installed record.
2. A controlled independent-writer simulation changed only A's disposable JSON to **Newer saved
   conflict A**, added **Independent saved credit**, removed its replay history witness, and
   removed only the empty mirror obstruction. `newer-saved-A.json` records the exact newer bytes.
3. Navigated to B, typed **Queued retained B**, navigated to C, typed **Queued retained C**, then
   clicked Close while C remained focused. The old A request reported a typed permanent conflict;
   C was captured and all subsequent work stayed behind A. B/C files still held initial values.
4. While C remained selected, opened **Review Queued Conflict** for A. It identified A and one
   affected request, with discard disabled. Cancelled review, reopened it, opened the Save panel,
   and cancelled export. C's editor and all queued work remained; no saved metadata changed.
5. Exported `a-conflict.png Caption Recovery.json` through the Save panel into this disposable
   folder. Read-back confirmed the exact A request, baseline, history/change, committed-JSON
   receipt and private 0600 permissions. Discard became enabled only after verification.
6. Appended one newline to that disposable export, then clicked Discard. The app rejected the
   changed bytes, retained every request, showed an actionable export-verification error and
   disabled discard again. Newer A and initial B/C saved files remained unchanged.
7. Exported again, explicitly replaced only the test recovery export through the Save panel,
   and discarded the verified queued A request. The app reported one exported edit removed.
   Actual B/C JSON and XMP writes resumed and contained their unique captions, one history event
   each and pending=true. Newer A JSON remained byte-identical and A XMP remained absent.
8. C's editor still showed its queued caption. Close returned normally to Browser; normal Quit
   completed without Quit Without Saving. Native inventory confirmed the app stopped. Relaunch,
   folder reopen and Caption navigation displayed newer A plus retained B/C captions. All ten
   tracked artifact states/hashes remained identical across Close/Quit/relaunch. A final normal
   Quit and native inventory confirmed every QA app entry stopped.

All three PNGs retain their original SHA-256:
`0085b9606833f3f836b46901d34f57b70eef92ca95e840f75e655ccffb123037`.

| Artifact | SHA-256 / state |
| --- | --- |
| A metadata JSON | `3d11aed94ec641d04f3c90dfb5dbc6c49fec74163c6f5518f0d55212eb88596f` |
| B metadata JSON | `9ebec0d6c5cc05b0530b54dc082602f9bb8a344f615f84d3029c0f69eab7620f` |
| C metadata JSON | `222ea5da81a906e48430bb420f1cfa940446fbf0ab21e2bef9462fe91ff06b56` |
| A XMP | Absent, unchanged by recovery |
| B XMP | `b79b624d34c599a6f56b9091bea7ddc9fa30821909bd0b72f9cb949ae17b7587` |
| C XMP | `93b57b21d9d7a6bc616008bfe72fcb55bcbfdaa912118e245f3d288324272331` |
| Recovery export | `f1e1aa544cda9c18ee59d60e429ffebf5812b0bd84118caa91601b56bf6ebe0f` |

The export review ID is `E9122179-34C0-43E1-A2A4-FE23560CA12D`, request ID
`D729D7B0-2203-4127-B6E7-4AD6BA18EECC`. `verified-export-original.json`,
`after-recovery-manifest.json` and `after-relaunch-manifest.json` retain local evidence.
The source and broad accessibility/IME, real-volume and external gates are not inferred from
this narrow synthetic interaction. Native same-photo guarded reload and stale callback injection
remain separately characterized by the existing tests/source review; this native run reviewed A
while C was selected.

## Field-write implementation scope

The service and Browser/Face callers implement exact field-only acknowledgement rather
than clearing an entire pending metadata record. Add-person physical mutation needs a bounded
atomic engine helper using its existing photo lock, preserving destination order with
case-insensitive deduplication and returning exact read-back evidence. Caller admission must be
ordered; cancellation alone cannot prevent an older rating/label write overtaking a newer one.

Rating clear uses canonical zero. XMP-only label clear can currently fall back to the embedded
label because existing merge semantics ignore empty labels. The service must retain pending state
and report an effective-clear failure rather than claim success; a carrier/merge correction remains
mandatory if not implemented in this slice. The final source/tests and native dispositions are recorded below; the effective-clear correction
remains mandatory.

## Native field-write baseline reproduction

Before rebuilding, the same `7a503b3` binary opened `build/qa-field-write-cycle7-baseline/`.
Its synthetic PNG and XMP were copied from the passing cycle-5 fixture and actually contained
Headline F, Description V5 and independent credit C. The app JSON held pending **Unwritten
headline G**, with a known original snapshot of those physical values. A separate second photo
has an intentionally nil original snapshot for the final regression run.

Selected `pending.png` in Browser and invoked Rating & Label → 3 Stars. Actual read-back showed
rating 3 in JSON, **pending=false**, JSON/XMP Headline G, but embedded PNG still Headline F.
The rating-only operation falsely completed an unrelated pending caption and prematurely mirrored
that caption into XMP. `after-baseline-rating.json` records the observed JSON. This is a real
native baseline defect, not merely an injected service test. The coordinator quit normally and
native inventory confirmed the old build stopped before compilation.

A fresh, identical `build/qa-field-write-cycle7-final/` folder is ready for retesting. Final rating
and label actions must affect only those physical fields while G stays pending, preserve an
existing nil snapshot, retain unrelated metadata and report actual partial failures.

## Integration checkpoints and bounded review

Initial focused builds stopped before tests: v1 found new physical-mutation enum names colliding
with legacy metadata field types; v2 found overlapping `metadata.xmp` access in the person-list
engine helper; v3 rejected an if-expression used directly as an append argument. The new types
were uniquely named without altering legacy types, the list was computed before mutation, and
Face result selection now uses a local assignment. Logs use the prefix
`/private/tmp/aagedal-coordinator-cycle7-focused-vN.log`. None of these compile failures is a
passing verification result.

Independent bounded review required atomic live person-list mutation and ordered caller admission;
then it caught historical prepared records being published over newer preserved JSON and lost
uncertainty across rapid A-uncertain/B-precommit-failed actions. Both caller issues now retain
truthful pending/error evidence without a fake rollback or stale field publication, with regressions.
Preparation records a JSON commit before read-back so failure reports durable unverified data.
A parent review also found cancellation wrapped as an ordinary physical error; cancellation and
possible-write flags now survive independently. Source tests cover cancellation before and after
possible embedded mutation. Final bounded reviewer recheck passes; execution results remain below.


Focused v4 stopped at test compilation (a main-actor write-mode convenience property in a
recorder actor, and missing CoreGraphics test import); both test-only fixes are explicit.
Focused v5 ran 117 tests in six suites and failed with eight issues: two Optional.none
assertions selected nil rather than enum none, two label assertions expected Red rather than
the app's canonical Select, and the effective XMP label-clear guard failed. A method-filtered
diagnostic selected zero tests and is not evidence. The whole service diagnostic then ran
14 tests and isolated three remaining clear-guard issues: actual physical label was Select,
target was XMP and request was clear, but overloaded enum-case/normalizer names made the
nil comparison ambiguous. The normalizers were given unique names before rerunning.
Temporary diagnostic output was removed from final source.


## Final automated checks before native Face follow-up

After unique normalizer names and corrected test contracts, focused v6 passes **117 tests in six
suites (4.296 seconds)**. The integrated suite passes **2,546 tests in 284 suites (95.517 seconds)**.
`scripts/ci/validate_repository.sh` passes. Logs are `/private/tmp/aagedal-coordinator-cycle7-focused-v6.log`,
`/private/tmp/aagedal-coordinator-cycle7-full.log` and `/private/tmp/aagedal-coordinator-cycle7-repository.log`.
Any later application change requires affected and integrated revalidation.

## Native Browser field-only completion — PASS

The tested dirty implementation on baseline `53d0ef8` is Debug 3.0.0 (738), arm64, macOS 27.0
(26A428), at the usual DerivedData Debug app path. `build/qa-field-write-cycle7-final/tested-binary-identity.json`
records executable SHA-256 `b61a82947532416ba61fd3a8d2f0d8d481f6cb20d99891f533e94be51c949fa5`
and debug dylib `067eff52fe4c3582a5abdf1f2a0a751123cdc63b288ef78b13d68885fa6de080`.

On fresh `pending.png`, clicked the metadata panel's three-star and Blue-label controls. Browser
shows 3 stars, Blue, **Pending metadata changes**, and the Headline pending indicator. Actual PNG
and XMP contain rating 3 / label Review while Headline F, Description V5 and independent credit C
remain unchanged. JSON retains Headline G and pending=true, with only the acknowledged rating/label
updated in its known original snapshot. `after-rating-label-snapshot.json` records read-back.

On `nil-snapshot.png`, five stars and Red produce physical 5 / Select while the original snapshot
remains null and G stays pending. Successive two-star/four-star actions finish at four in all three
destinations. Clicking the selected fourth star and Red again clears to physical rating zero / no
label and JSON nil fields, still pending with null snapshot. Both PNG pixel payload hashes remain
unchanged. Snapshot files record each step. Normal Quit was confirmed by native app inventory;
relaunch and folder reopen show both correct rating/label states, pending markers and G in the
editor. All tracked artifact states match exactly after quit/relaunch.

The native menu AX entries intermittently returned stale-element errors and menu keyboard actions
had no effect. Its exposed Cancel action recovered the menu; actual metadata panel controls then
completed all writes. No menu success is inferred from attempted actions. A screenshot was unavailable;
accessible native controls and independent file read-back provide the recorded evidence.

A separate failed-rating action on the Face fixture's `failed.png` with a nonempty directory at
`failed.xmp` correctly rolls back the optimistic rating to zero and shows **0 of 1 photo metadata
edits completed**. Details names failed.png and the invalid-format reason. All fixture bytes remain
identical (`after-browser-failure-snapshot.json`).

## Native Face initial run and diagnosis

`build/qa-field-write-cycle7-face/` loads the saved synthetic **Cycle 7 Added Person** group with
two faces. AuraFace inference is unavailable but the saved-group Apply control is enabled. Two
Apply attempts made no metadata changes and showed no error, including in expanded Face manager.
The caller/view integration was diagnosed and corrected as recorded below; the initial fixture
and snapshot remain intact. This is separate from the passing injected caller/service tests.


The native Face diagnosis is concrete: decoded fixture folder URLs omit the terminal directory
slash, while Browser's selected folder URL includes it. Swift URL equality remains false after
standardization even though canonical paths match. The newly added folder guard therefore reports
that the folder changed before any writes. No view currently presents FaceRecognitionViewModel's
operation error, so the rejection is silent. The correction normalizes directory identity at these bounded caller seams and presents full
accessible Face operation errors, with a trailing-slash regression. The QA build was stopped
before the correction and rebuild.


## Final integration and handoff

Implementation is committed as **`34a7313a2d1d2cb01cd9cbf20e22f11a746fa249`** (ten owned
source/project/test files; documentation committed separately). The Face folder identity helper
now compares normalized directory paths at admission, completion and rename pause boundaries.
FaceBar presents full selectable, scrollable operation details when an error occurs and retains
accessible Details/dismiss controls. The actual Apply All regression covers both directory URL
hints. Independent final narrow review passes.

Final focused v7 passes **24 tests / two suites (0.704 seconds)**. Integrated v2 passes **2,547
tests / 284 suites (106.900 seconds)** and repository v2 validation passes. Exact commands are the
coordinator's standard xcodebuild test command; focused v7 adds only-testing selectors for
MetadataFieldMutationWriteServiceTests and FieldMutationCallerTests. Final logs use
`/private/tmp/aagedal-coordinator-cycle7-focused-v7.log`, `...-full-v2.log` and
`...-repository-v2.log`. The full result bundle is `Test-Aagedal Photo Agent Tests-2026.09.10_16-49-16-+0200.xcresult`
under the project's DerivedData Logs/Test directory. Known framework MDB_MAP_FULL diagnostic noise
did not fail either passing suite; no cache reset was performed.

The unchanged source was built before its commit, with the ten staged implementation files on
baseline `53d0ef8` and dirty documentation. Final binary identity is recorded in
`build/qa-field-write-cycle7-face/tested-binary-identity-final.json`: Debug 3.0.0 (738), arm64,
macOS 27.0 (26A428), SDK macosx26.5, executable
`b9e11786155ab97595ec39366388e3fc3bcc0752787d3fb6498ad56d234f1a86`, debug dylib
`dd5de8b406b1587f7c389e947ac33834be3f5d02654b9d79eec671ac924ac8c1`.
The app path is `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.

After final tests, CUA launch reported that the Mac was locked and automatic unlock unavailable.
The prior QA process had been quit and independently confirmed stopped before building. Final
Face Apply/partial-error/retry/relaunch interaction is therefore **pending**, not a passing test.
The saved-group fixture remains intact and requires no inference download. Recheck desktop access
next cycle before rebuilding unchanged source. Other mandatory implementation work remains, so this
host condition does not justify a blocker handoff or stopping the automation.

The HTML checklist adds A16 (31 cases total) for field-only writes, retained pending values,
per-destination names, partial outcomes and effective clear semantics. Candidate identity is still
blank and human results unrun; HTML visual validation and full readiness gates remain open.
No broad acceptance criterion is checked by this cycle. Continue with the ordered readiness actions:
finish native Face, then effective XMP clear, orientation, Metadata Review, batch/variable completion,
and remaining archive/reassociation, transcription, delivery and wider release verification.


A second native availability check after the source commit and documentation still reported the
Mac locked. No unlock bypass or user notification was attempted. Final static checklist checks
pass: 31 unique complete cases (16 agent, six user, nine external), all case source links resolve,
and `node --check /private/tmp/aagedal-cycle7-checklist-final.js` passes. No human outcomes were set.
