# Cycle 11: native Metadata Review retry and scoped recovery

PASS for the bounded cases below on implementation `f897bdd08e9dd8efab6ca9de7f626080cbc99736`.
This closes the ordinary retry/export/discard native continuation from cycle 10, not the broader
release gate or every A03 case. The full 2,585-test cycle-10 evidence remains valid for this
unchanged binary; no redundant full run was performed. Cycle-11 Write All source work began
independently but was not built or included in this native evidence.

## Identity and environment

Debug app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Version 3.0.0 (738), arm64, macOS 27.0 (26A428). The executable, debug dylib and preview dylib
hashes were rechecked after the final relaunch and match
`build/qa-metadata-review-cycle10/tested-binary-identity.json` exactly; see the
[cycle-10 report](cycle-10-metadata-review-2026-09-11.md) for all hashes.

The app was stopped initially. Resetting only the CUA JavaScript session restored usable native
access. Some native menu element IDs still became stale; a fresh state plus native End/Return
menu selection worked. No permission, lock, or browser-policy bypass was used. No write-mode
preference was changed. The existing automation continued; other active tasks used other repos.

Fixtures: `build/qa-metadata-review-cycle10/failure`, initially six files matching the existing
initial manifest. These are synthetic PNGs and owned JSON copied for QA, not user photographs.
The passing `happy` folder was not modified. All test source PNGs remain byte-identical.

## Partial save and retry

1. Opened the failure folder and Metadata Review; waited for editable baseline rows.
2. Created only an empty directory at `a-known.xmp` after the baseline loaded.
3. Typed `Review retry retained headline R11` for a-known, then focused b-null. The app displayed
   Queued Metadata Needs Attention, the exact affected photo, and Retry Saving. Read-back showed
   a-known JSON had committed R11 with one history entry and original F; XMP could not finish.
   The source PNG and other original artifacts were unchanged. An initial check assuming no JSON
   commit failed; inspection confirmed this was the expected partial-commit case, not data loss.
4. Typed `Review queued second photo S11` for b-null. Back to Browser remained blocked with the
   retained-save error; the visible drafts remained available.
5. Removed only the empty obstruction and clicked Retry Saving. The banner cleared. JSON and
   XMP contained R11 and S11, each with one history entry. a-known retained original F; b-null
   retained its absent original snapshot. No duplicated history or source write occurred.

Evidence: `cycle11-blocked-save-snapshot.json` and `cycle11-after-retry-snapshot.json` in the
ignored fixture root.

## Retry with a still-present applied history witness

A second blocked request committed R12 JSON before its mirror failed. An independent test edit
then changed the saved headline to E11 while retaining the queued request's exact history witness.
After restoring the saved XMP baseline, Retry Saving correctly used the newer authoritative
record: it preserved E11 and completed its mirror rather than overwriting it with R12. The other
photo's S12 also saved. This is successful idempotent replay, not a permanent conflict.

Evidence: `cycle11-external-conflict-snapshot.json`, `cycle11-after-witness-retry-snapshot.json`,
and `cycle11-a-before-conflict.xmp`. The first filename records the test intention; the observed
outcome was a valid applied-witness retry.

## Permanent conflict, cancellation, export and scoped discard

1. Blocked a-known's XMP again while retaining an exact backup. Typed
   `Review exported pending headline R13`, then queued `Review scoped recovery survivor S13`
   for b-null. a-known's JSON committed; its mirror remained blocked.
2. Replaced only disposable a-known JSON with an independent record headed
   `Independent replacement record E12`, preserving its other fields/original but removing R13's
   history witness and recording the independent replacement. Restored the exact pre-conflict XMP.
3. Retry Saving now exposed Review Queued Conflict. The newer files were preserved.
4. Opened recovery while b-null was selected/focused. The sheet named a-known and one queued edit.
   Cancel kept both visible drafts. Reopened it; cancelling the Save panel kept Discard disabled.
5. Exported `failure/cycle11-a-known-recovery.json`. The UI confirmed verified export and enabled
   Discard. Inspection confirmed only the a-known request, full R13 metadata/history, original F,
   request ID `CB60C419-259E-4E04-84E5-AFF326B15838`, and `jsonWasCommitted: true`.
   Export SHA-256: `9cd96d0d04842436123c3f8f9c1b6846a5e52a4de737662c5b024b07906af457`.
6. Explicitly discarded the exported queued edit. The UI reported one removed request and that
   saved files/other queued photos were kept. a-known was no longer the selected row; its Load
   Saved Metadata button reloaded E12. b-null showed S13 with no original snapshot.
7. Verified a-known PNG, JSON and XMP exactly match the pre-discard external record; S13 was saved
   to b-null JSON/XMP. a-known history count is four; b-null count is three. c-first and d-untouched
   remain without app JSON/XMP, and every source PNG remains unchanged.
8. Left Review, quit normally, confirmed native inventory stopped, relaunched the same binary,
   reopened the folder and Review, and observed E12/S13 with no conflict banner. An inline
   screenshot confirmed those values. Final artifact snapshots match exactly. Quit normally again;
   native inventory confirms every Aagedal Photo Agent entry stopped.

Evidence: `cycle11-a-before-scoped-conflict.xmp`, `cycle11-before-scoped-recovery-snapshot.json`,
`cycle11-after-scoped-discard-snapshot.json`, `cycle11-after-final-relaunch-snapshot.json`, and
`failure/cycle11-a-known-recovery.json`. Screenshots were observed inline, not saved as standalone
files. Both temporary XMP obstructions were removed; backups and the verified export are retained.

## Limits and next work

This run does not establish IME/VoiceOver correctness, more than 20 native field edits, lazy row
recycling, corrupted export rejection, unwritable export, or disappearance during an in-flight
discard. Those retain their separate automated/source evidence and required manual gates. The
pre-existing accessibility Value/Help behavior noted in cycle 10 remains for the VoiceOver audit.

Independent source audit found a high-priority Write All defect: its Void embedded writer skips
RAW, yet the caller can delete pending JSON and count success; existing XMP can also shadow an
embedded write after cleanup. A bounded verified completion service and caller migration are now
being implemented by separate agents. Variable-writer acknowledgement/folder-capture defects are
recorded separately for the following slice. No production transfer or release action occurred.
