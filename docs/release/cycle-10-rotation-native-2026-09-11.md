# Cycle 10 — native rotation continuation

## Identity and scope

Native checks used unchanged implementation `b5840e4304450dce9371b5c2329e230635adf351`,
Debug 3.0.0 (738), arm64, macOS 27.0 (26A428). The exact app and all three executable hashes
still match `build/qa-rotation-cycle9/tested-binary-identity.json`. Concurrent Metadata Review
source edits were not built into this app. The prior 2,569-test integrated run remains its
regression evidence; no unchanged-source rerun was needed for these native checks.

The Mac was accessible on the first continuation check. Settings showed Professional selected,
confirming cycle 9's failed Custom click had not changed the preset. The fixture folder contains
two copies of the synthetic nonsquare PNG and pending headline G: known.png has a saved original
snapshot; unknown.png has null. Initial embedded headline is F, description V5, credit C.

## Observed native results

1. Selected Custom, then Standard Images / Save History Only. Rotated known.png right with
   Command-R and unknown.png left with Command-Shift-R through the actual Browser.
2. Both thumbnails became portrait with opposite orientations; unknown.png full-screen matched
   its thumbnail and displayed the pending marker. JSON targets were respectively 6 and 8;
   original PNG bytes stayed identical and no XMP file was created.
3. Quit normally, confirmed all native app inventory entries stopped, relaunched and reopened
   the folder. Both portrait thumbnails and their opposite angles persisted.
4. Selected known.png and clicked the toolbar's Write All Pending. The metadata panel displayed
   the complete explanation: zero written, two failed, a pending rotation must first be applied
   using a physical mode and Write Pending Rotation. Every saved artifact state remained equal
   to its post-history state.
5. Selected Custom / Write To Image File + XMP Sidecar. Used each photo's actual right-click
   **Write Pending Rotation** command. No additional rotation command was issued. Readback shows
   EXIF and both embedded XMP orientation conventions equal 6/8; new XMP sidecars contain the
   matching orientation. Each technical draft is removed, while both caption drafts remain pending.
6. After task interruptions, reconnected to the app and verified those physical results. Restored
   Custom Standard Images = Write To Image File, then Professional; returned Settings to General
   and closed Settings. RAW/C2PA settings remained XMP throughout.
7. Reopened the folder in the unchanged binary. Both thumbnails still showed their same portrait
   angles. Quit normally; native inventory confirms every Aagedal Photo Agent entry stopped.
   Final artifact states exactly match the post-apply snapshot.

The original JSON metadata and original snapshots are unchanged, including null. History grows
by one rotation event per photo and does not grow during same-target apply. The PNG IHDR/IDAT
pixel payload hashes are unchanged. Embedded F, V5 and C are retained; pending G is not written
into the source. These are observed passing history-only, dual-apply, admission-error and
persistence cases, not a claim that all destination/failure/hardware scenarios have native coverage.
XMP-only and partial-write failure paths have automated coverage but were not newly exercised here.

## Evidence and remaining work

Evidence directory: `build/qa-rotation-cycle9/`. Readback files:

- `cycle10-after-history-snapshot.json`
- `cycle10-after-history-quit-snapshot.json`
- `cycle10-after-reopen-writeall-snapshot.json`
- `cycle10-after-apply-snapshot.json`
- `cycle10-after-final-relaunch-snapshot.json`

The first three match, including original PNG bytes. The final two match, including the new XMP
files. The inspector is `build/qa-rotation-cycle9-tools/inspect.py`. Screenshots were observed
through native computer use; the report records those visual outcomes without claiming saved PNG
screenshots. Tool-session resets and task interruptions were handled by reacquiring actual app
state; no stale menu action or assumed preference outcome was used.

Cycle 9's native setup/cleanup blocker is resolved. Metadata Review retained replay/recovery is
in progress on top of baseline `5afb5f3`; its changes need separate build, test and native evidence.
All broad feature, accessibility, interoperability, performance, external and final-candidate gates
remain open. No final user acceptance or release publication occurred.
