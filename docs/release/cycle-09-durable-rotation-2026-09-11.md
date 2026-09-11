# Cycle 9 — durable pending rotation and verified completion

## Source and decision

Baseline `9d65002` was clean. Implementation commit
`b5840e4304450dce9371b5c2329e230635adf351` changes sixteen source/test files.
State remains **IMPLEMENTING**. Rotation implementation and automated verification pass;
its native history/write/relaunch gate remains open because the Mac locked during test setup.
No authoritative plan checkbox or final acceptance gate was closed. All 60 unchecked plan
entries remain visible; this slice does not replace their broader criteria.

The existing coordinator automation remains active. Task inventory through `list_threads`
did not return during this cycle and its waiting orchestration was terminated. Git inspections
showed only the coordinator's assigned source changes and checklist update; no unrelated work
was overwritten. Core, Browser and independent review agents had bounded ownership; the
coordinator alone built, operated the GUI, integrated and committed.

## Implemented behavior

- Browser clockwise/counterclockwise actions use ordered immutable per-photo expected→target
  field requests, capturing folder, destination mode and C2PA/RAW routing at admission.
  Later actions do not cancel earlier accepted rotations. Verified fallback and uncertain
  completion handling preserve unrelated pending captions and stale-selection boundaries.
- JSON gains a typed top-level `orientationDraft` with stable intent ID, target and separately
  observed embedded/XMP baselines. `IPTCMetadata` still omits orientation and Camera Raw from
  its editorial JSON projection. History-only rotation now has a durable payload and marker.
- Ordinary owned saves, Caption replay and explicit pending saves preserve that technical
  draft and pending status. Existing null original snapshots remain null. Only verified
  orientation completion removes the rotation intent; editorial differences remain pending.
- Physical field writes preserve unrelated metadata and Develop, update EXIF plus embedded
  and sidecar XMP orientation conventions, and verify readback. RAW stays sidecar-routed.
  Per-destination baselines allow retry after partial embedded/XMP outcomes without accepting
  an unrelated orientation change. A new turn after partial completion rebases on the actual
  verified destination values; it cannot strand its own previous physical result.
- Browser's **Write Pending Rotation** context command applies the currently displayed target
  without an extra turn, using the current write mode. Thumbnail and full-screen readers
  prefer the durable target over the physical baseline while the rotation remains pending.
- Whole-record completion/cleanup, legacy and batch metadata writes, variable writes,
  rendered export (including DNG), and normal FTP preprocessing/upload admission reject an
  unresolved rotation before their physical work. The error directs the user to choose a
  physical mode and use Write Pending Rotation. Write All retains the first concrete failure.
  New asynchronous UI admission checks recheck cancellation/selection or inspection identity.

These admission checks are not a freeze over the entire export or legacy writer lifecycle.
Their wider concurrency/replay work remains open. The now-unreachable legacy Browser helper
chain remains in source; rotation no longer calls it. External empty element-form XMP Label
interoperability and the remaining Metadata Review/batch/variable migrations are unchanged.

## Automated verification and review

Commands used the Debug `Aagedal Photo Agent Tests` scheme, macOS destination and
`-parallel-testing-enabled NO` with the existing Xcode project.

| Run | Observed result |
| --- | --- |
| Initial focused, four suites | 117 tests; 11 assertions failed in two new fixture cases. Metadata editor and export suites passed. |
| Focused v2, field service and callers | 40 tests; all core tests passed. Two new Browser path assertions still failed. |
| Focused v3, Browser/Face callers | 15 tests / one suite PASS in 0.278 s. |
| Final integrated | **2,569 tests / 285 suites PASS in 89.697 s.** |
| Repository validation | PASS, including JSON/plist/privacy checks; final whitespace check PASS. |
| Independent source review | Bounded PASS after both destination-baseline issues were corrected. |

Initial failures were test construction defects, not suppressed product failures:

1. The Browser test selected an independently constructed URL instead of its enumerated image
   identity, so no image was selected and no rotation was requested. It now requires a real
   selection and completed per-photo result. Its follow-up path assertions compared `/var`
   with `/private/var`; canonical filesystem paths now match. Actual rotation, reload and
   same-target apply passed in v2 before those final assertion corrections.
2. The dependency deliberately ignores `setOrientation(9)`, so the invalid-baseline fixture
   never became invalid. The test now injects malformed embedded facts through the existing
   read boundary while using real XMP/JSON/source files, proving fail-before-write behavior.
   Invalid persisted draft decoding remains separately tested.

Meaningful regressions cover history-only chains/reload, expected-value conflict, each physical
mode with known/null snapshots, destination-only metadata and opaque Develop preservation,
partial commit/retry, partial A→new B→prephysical cancellation→retry, RAW routing, malformed
baselines, Caption retention, whole-record admission and export-before-artifact checks.
Framework `MDB_MAP_FULL` diagnostic noise appeared in passing runs; no shared cache or daemon
reset was performed.

Logs: `/private/tmp/aagedal-coordinator-cycle9-focused.log`, `-focused-v2.log`,
`-focused-v3.log`, `-full.log`, and `-repository.log` (each uses the same cycle9 prefix).
No test files needed new Xcode project registration.

## Native setup and exact remaining work

The full-suite build was launched through native computer-use tools:

- App: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`
- Debug 3.0.0 (738), arm64, macOS 27.0 (26A428).
- Executable SHA-256: `3fb1e788b480d49dec0eee45f8293328b8f4663f8613805a0d5b0fd9087e90cb`.
- Debug dylib SHA-256: `dddd3c37c1d9c6e0647df51ff157c7e3bac128130e80458b35e509a4b9d0e87d`.
- Full identity: `build/qa-rotation-cycle9/tested-binary-identity.json`.

Native launch and the Open Folder chooser succeeded. The disposable
`build/qa-rotation-cycle9/` directory was opened. Its known/unknown PNGs are copies of the
cycle-7 synthetic 640×400 fixture, with pending headline G and known/null original snapshots.
They have no initial XMP companions. The initial JSON/source bytes were recorded.

Settings opened with **Professional selected**. The next click on **Custom** returned the
computer tool's locked-Mac error. A later accessibility recheck returned the same lock error.
No rotation, Write Pending Rotation, Write All or export interaction was performed. The click's
preference outcome is unverified; the app was not confirmed stopped. There was no unlock bypass.

**Resume cleanup first when native access returns:** inspect the still-open Settings window.
Original preset is Professional; the saved Custom Standard Images mode is Write to Image File,
RAW/C2PA use XMP. Complete the intended history-only setup, native rotation/write/relaunch tests,
then restore those preferences, return Settings to General and quit normally. Verify native
inventory before claiming the app stopped. Do not blindly assume the failed Custom click applied.

`before-native-snapshot.json` and `after-native-attempt-snapshot.json` prove all four original
PNG/JSON artifacts are byte-identical after this setup attempt. The later snapshot additionally
includes the binary identity file. The inspector in `build/qa-rotation-cycle9-tools/inspect.py`
records PNG pixel payload, EXIF orientation, both XMP orientation conventions, metadata/history
and the typed draft. Compare original artifact keys when identity/evidence files were added later.

Required native continuation: rotate the nonsquare fixtures in history-only mode; inspect
thumbnails/full-screen, pending captions and null snapshot; quit/reopen; exercise the full-record
admission error; select a physical mode and Write Pending Rotation; verify destination tags,
unchanged pixel payload, no extra turn/history, retained captions and final relaunch. Automated
cases do not substitute for these observations.

## Handoff

The HTML checklist's A16 now describes durable rotation, reopen, admission errors and same-target
apply in addition to rating/label/Face checks. It remains a draft with no candidate or human results;
its visual-open gate is still unresolved under the previously recorded local-file URL policy.
Static checks pass for all 31 complete cases, unique IDs, local source links and JavaScript syntax.

Recheck native access/restore pending test preferences, then continue Metadata Review retained
replay/recovery and the remaining writer migrations. Sony archive/reassociation, transcription,
delivery, broader UI/performance/hardware/interoperability and external prerequisites remain.
Substantive implementation and verification occurred; no-progress counter stays zero. This single
native blocker does not justify pausing the automation or notifying for final user testing.

## Cycle-10 follow-up

[Native continuation](cycle-10-rotation-native-2026-09-11.md) passes history-only rotation,
full-screen/relaunch, visible Write All refusal and same-target dual apply on unchanged `b5840e4`.
Preferences are restored and native inventory confirms the QA app stopped. Earlier pending setup
and untouched-fixture notes above are historical; final fixture values are recorded in that report.
