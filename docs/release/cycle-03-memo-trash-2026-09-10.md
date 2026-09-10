# Coordinator cycle 3 — recoverable memo Trash and shared metadata

**Date:** 2026-09-10 Europe/Oslo (started 2026-09-09 22:19 UTC).
**Baseline:** `fee5b0d` on `main`; clean checkout. The previously preserved Xcode reference
ordering was committed separately before this cycle. No other active task used this checkout.
**State:** implementation committed and integrated validation passed; release implementation continues.
**Implementation commit:** `ef0250721a8534368ddfdef0815c1408f43f0220`.

## Implementation and independent review

A sub-agent implemented companion-aware Trash on the retained filesystem executor. A photo
with a persisted memo is moved into one visible `<photo> Photo Agent Trash <UUID>` folder,
with its relationship and owned metadata, before one system Trash call. Shared WAV/XMP bytes
are copied so surviving photos retain their carriers. Legacy JSON explicitly owned by another
photo is preserved and omitted. Regular opaque XMP bytes are preserved without interpretation;
JSON needs readable ownership. Unsupported/missing associations and unsafe links fail closed.
Original-byte retirement checks, cancellation before commit, rollback paths and uncertain
post-Trash failures are explicit. Restore the entire folder from Finder Trash and open it in
Photo Agent; this retains the hidden relationship and metadata hierarchy. Photos without a
persisted relationship retain their existing direct Trash behavior.

A UI sub-agent added recovery guidance to both browser/fullscreen and face-group confirmation.
Browser errors now offer a scrollable, selectable Details view with every failure and recovery
path. Face-group deletion surfaces failures after its initiating group disappears and explains
whether face data changed. Committed counts and uncertain outcomes remain distinct. Ordinary
success stays quiet.

Independent review found and drove fixes for a shared-memo ownership snapshot race and for
two existing Move/Reject metadata defects: stem XMP could be consumed from a surviving image,
and a legacy JSON record declaring that sibling as owner could be moved/deleted or adopted.
The coordinator added conservative sibling discovery and legacy owner checks. Shared XMP is
copied; other-owned legacy JSON stays at source. Copy preparation uses private staging and
exclusive installation, including failure/racing-destination tests. Reject checks siblings
in its metadata tail rather than before long image preparation. The final bounded review
reported no unresolved blocking finding in this slice.

This is not a global storage-ownership or process-crash-atomicity claim. External-writer races
at filesystem boundaries, physical cross-volume/power-loss drills and broader migration/save
ownership remain gates. Shared-copy staging cleanup is best-effort. Existing direct no-memo
Trash behavior does not establish complete arbitrary-photo sidecar lifecycle coverage.

The [archive and reassociation design](voice-memo-archive-design.md) traces all RAW conversion,
signing and cleanup paths. It is a proposal, not implementation or validation. Transcription,
reviewed variables, Deadline audio policy and archive/reassociation remain required.

## Fixtures and native baseline

`build/qa-voice-memo-cycle3/` contains copies of the cycle-1 generated PNG and silent 12-second
PCM WAV, with exclusive, two shared-owner, missing and no-memo cases plus an unrelated WAV.
`fixture-manifest.json` records original bytes. No private images or speech were used.

The Mac was unlocked and the exact prior Debug app launched via CUA. Five fixture images
loaded. Cmd-Delete displayed confirmation; Cancel retained all five. Rename preview showed
one memo and one relationship moving when the proposed filename changed; Close retained the
original name. Caption showed `exclusive.WAV`, `0:00 of 0:12` and Play without autoplay.
The app was quit before integration, and native inventory confirmed it stopped.

## Automated and native verification

Initial compile attempts found one ambiguous CGFloat constant in the
new native details view and two missing throwing-call annotations in Trash guards; these were
corrected. Logs are `/private/tmp/aagedal-coordinator-cycle3-focused.log` and `-focused-v2.log`.
No failed build counts as passing validation.

Two subsequent focused attempts compiled app/tests but executed zero tests: XCTest's control
XPC connection failed and its daemon-session handshake timed out before app launch. See the
[diagnostic record](cycle-03-test-launch-diagnostics.md). The coordinator interrupted only its
own stalled `xcodebuild` processes; their test hosts stopped automatically. No global daemon,
other app, build setting or source cache was reset. A post-resume retry is recorded separately.

Repository checks passed (`/private/tmp/aagedal-coordinator-cycle3-repository.log`). The updated
HTML passed static checks for 29 complete cases, unique IDs, local source links and JavaScript
syntax. Browser visual/interactive checklist QA remains blocked as previously recorded.

## Observed native Trash and recovery

The rebuilt Debug app is **3.0.0 (738), arm64**, at the cycle-2 DerivedData bundle path.
Its executable SHA-256 before the post-resume test retry was
`c11f0e161f508452c67d78b5ffc7d72e1b8c73003b8cb02c340d8ed7e029ab7c`.
No source edits occurred between this build and these native observations.

- Cmd-Delete on `exclusive.png` exposed the entire recovery explanation in native AX and an
  unclipped screenshot. Confirmation removed the photo, WAV, relationship and caption sidecar
  from source; Browser immediately showed four images and selected the nearest survivor.
- Trash on `missing.png` left four images and the selected source intact. Its banner reported
  zero moved and one issue. Details opened a native scrollable text view exposing the full
  path, missing WAV filename and recovery instruction. Selecting the recovery sentence
  succeeded. No clipboard overwrite was needed. This short message did not require scrolling;
  long-message native scrolling and Face Group interaction remain broader validation cases.
- Trash on `shared-a.png` left three images and selected `shared-b.png`. Caption still resolved
  `shared.WAV`, 12 seconds. Play changed to Pause and the position advanced to six seconds;
  Pause stopped it. The silent synthetic audio establishes playback state, not speech quality.
- Computer access then paused for hours within the Finder tool call. On return at approximately
  10:00 Oslo, source status and fixture paths were rechecked before continuing; they were unchanged.
- Separate Finder windows displayed only the two generated Trash bundles. Put Back restored
  each complete folder inside the original fixture folder. No empty-Trash or permanent-delete
  action was used. The temporary Finder windows were closed, returning to its original window.
- SHA-256 checks proved exact recovery of exclusive photo/WAV/record/caption bytes and shared
  photo/WAV/record bytes. The root shared survivor, missing case, plain photo and unrelated WAV
  retained their original bytes. Restored folders remain in the ignored cycle-3 fixture tree.
- Opening the exclusive restored folder in Photo Agent showed its pending caption,
  `Synthetic cycle 3 recovery caption`, and `exclusive.WAV 0:00 of 0:12`. Play changed to Pause.
  Playback was stopped and the QA app was quit before retrying automated validation.

Recovery folders are `exclusive.png Photo Agent Trash EFD48046-8B42-4CE4-B2DF-92FBD4CFB661`
and `shared-a.png Photo Agent Trash 409E12FF-1FF3-4A68-A960-D2C4802208F6`. Keep their contents
together. Synthetic recovery is narrower than authentic Sony, physical-volume and crash drills.

## Final integrated results and handoff

After host access resumed, the unchanged source passed **119 tests in five focused suites**
in 2.653 seconds (`/private/tmp/aagedal-coordinator-cycle3-focused-post-resume.log`). The final
unfiltered run passed **2,445 tests in 278 suites** in 91.063 seconds
(`/private/tmp/aagedal-coordinator-cycle3-full.log`). Both report `TEST SUCCEEDED`. Final
repository checks passed (`/private/tmp/aagedal-coordinator-cycle3-repository-final.log`).
No code change preceded this slice's commit after those checks. An independent reviewer approved this bounded slice
for local commit after these checks passed; source is committed as identified above.

The final tested Debug executable hashes are:

- `Contents/MacOS/Aagedal Photo Agent`: `9b7bff84f5ac2d6c9e20527cf96174aea6ae1ccc43b498345d453ac3fcc2d969`
- `Contents/MacOS/Aagedal Photo Agent.debug.dylib`: `fdf061ffa96a97ae71e4ead5cfbbdc0fe5c55a8568e33284a6d872049bd1f432`

A final relaunch initially met stale native menu references. Resetting only the CUA JavaScript
session recovered access; Open Folder then reopened the restored bundle. Caption still showed
the saved text and `exclusive.WAV 0:00 of 0:12` without autoplay. The QA app was quit and native
inventory confirmed all Photo Agent entries stopped. No final release candidate was packaged.

One follow-up observation prompted a separate correction: although the recovered JSON was byte-exact
immediately after Finder Put Back, normal Caption viewing/quit later changed its `lastModified`
and filled `imageMetadataSnapshot.description` with the pending caption. The pending caption
itself remained intact and no editing control was changed. The fixture's source PNG/WAV/record
remain exact. This is distinct from Trash recovery. The [Caption follow-up](cycle-03-caption-baseline-2026-09-10.md)
confirms incorrect automatic persistence and records its correction, a reproduced failed-save
retry deadlock, separate validation and the remaining explicit Restore/history baseline work.
The first slice's hashes above identify its tested artifact; later integrated hashes are in
that follow-up. Neither report closes the broader storage/metadata gate.
Also audit legacy ownership in ordinary save/migration/clear paths; the new Move/Reject checks
do not cover every writer. Unusually long Unicode filename prefixes can safely fail recovery-
folder creation before mutation; filename robustness remains a nonblocking follow-up.
