# Sony Alpha voice-memo companion foundation — validation record

**Date:** 2026-08-24  
**Scope:** journalistic metadata workflow, Sony Alpha voice-memo association and rename safety

## Real sample evidence

The private two-card sample supplied on 2026-08-24 was recorded by a Sony ILCE-1 running firmware
4.00. Card 1 contains three ARWs (`TRA08907` through `TRA08909`). Card 2 contains the corresponding
three JPEGs and three WAVs in `DCIM/100MSDCF`.

For every stem, the ARW and JPEG report identical camera, firmware, `DateTimeOriginal`, subsecond,
UTC offset, and shutter count. The WAV filesystem times follow their exposures by approximately
36.907, 24.456, and 13.756 seconds. The files are stereo 48 kHz 16-bit PCM WAVs, with durations of
23.32, 21.08, and 11.99 seconds. A direct app-parser validation over the private sample produced
three associations with no ambiguity or orphaned WAV. The private media is not copied into the
repository.

This evidence establishes a lower-bound timing rule only: a voice memo can never predate its image,
but may be recorded arbitrarily later. No upper time window is used.

## Implemented boundary

The app has a carrier-neutral, profile-driven voice-memo association service. A profile must
explicitly provide the image extensions, audio extensions, filename case behavior, and optional
memo subdirectory.

Association fails closed. Exactly one image and one memo in a profile-defined key become an
association. RAW+JPEG pairs, duplicate audio, and case-folding collisions are reported as
ambiguities; image-without-memo and orphan-memo states remain separate and visible. Inputs are
canonicalized, de-duplicated, and deterministically ordered. Unsafe relative-directory components
are rejected.

A proven association can be projected into `RenamePlanningItem` as an explicit companion. The
immutable rename plan freezes the concrete WAV source URL and derives only its accepted destination
name from the image rename. The WAV participates in collision detection, destination reservation,
preview summaries, two-phase staging, commit, cancellation, and byte-for-byte rollback through the
existing `RenameExecutionService`. The executor never rediscovers or guesses the association.

The Import sheet accepts one media source or an optional second source. RAW and JPEG images on both
sources participate in the user's RAW Only, JPEG Only, or Both selection. A WAV can be anchored by
a same-stem RAW or JPEG on its own source; matching image variants on the other source join the
exposure only when their camera/firmware/capture/subsecond/offset evidence is identical. This covers
RAW+WAV, JPEG+WAV, RAW+JPEG+WAV, RAW on one card with JPEG+WAV on another, and the inverse layout.
Missing evidence, repeated variants, duplicate WAVs, cross-source WAVs without a same-source image
anchor, timestamp mismatch, or a WAV predating capture fails closed.

Accepted WAVs use the existing streaming copy, optional SHA-256 verification, backup, Activity, and
completion-summary paths. Image and WAV conflicts reserve one common suffix so the relationship is
not broken by independent renaming. Duplicate-image skipping also skips its WAV. WAVs are excluded
from the metadata-writing pass and from the browser's image list.

## Automated evidence

The original association-and-rename foundation command was:

```text
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/SourceImageDiscoveryServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/VoiceMemoAssociationServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/RenamePlanningServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/RenameExecutionServiceTests'
```

Result: **45 tests passed** across four suites.

The initial dual-card import follow-up ran the Sony evidence association, source discovery,
copy-prerequisite, and Import-view-model suites together. Result: **23 tests passed** across four
suites. A subsequent
unfiltered run passed **1,406 tests in 155 suites** with zero failures. The retained result bundle
is
`/tmp/aagedal-sony-dual-card/Logs/Test/Test-Aagedal Photo Agent Tests-2026.08.24_23-18-06-+0200.xcresult`.

The flexible one/two-source follow-up passed **27 tests across four focused suites**. The final
unfiltered run passed **1,410 tests in 155 suites** with zero failures. Swift Testing reported
48.901 seconds and Xcode reported 50.799 seconds. The current result bundle is
`/tmp/aagedal-sony-flexible-sources/Logs/Test/Test-Aagedal Photo Agent Tests-2026.08.24_23-30-44-+0200.xcresult`.

New coverage proves:

- unique case-sensitive and case-insensitive association under explicit synthetic profiles;
- validated nested memo-directory layouts;
- fail-closed RAW+JPEG, duplicate-WAV, and case-folding ambiguity;
- distinct missing-image-companion and orphan-WAV reporting;
- invalid/unsafe profile rejection;
- explicit-source rename planning without reconstructing the WAV source name;
- WAV destination collision blocking and preview summary inclusion;
- image+WAV transactional commit and injected-failure rollback with exact original bytes.
- exact dual-card stem and Sony capture-fingerprint matching with no maximum WAV delay;
- rejection when a WAV predates the image or when capture evidence, witnesses, or stems are
  ambiguous;
- shared conflict suffixes for imported image+WAV pairs and prerequisite failure propagation that
  prevents orphan WAV copies.
- one-card RAW+WAV association without requiring a JPEG;
- one/two-source RAW Only, JPEG Only, and Both selection, including importing JPEGs from the second
  source when requested;
- RAW+JPEG import with verified WAV copies beside both selected variants, and rejection of a WAV on
  another source when that source has no matching image anchor.

Portable synthetic tests validate negative and conflict boundaries. A separate one-off test against
the private sample validated the three real ILCE-1 v4.00 pairs through the production metadata
reader; its absolute path is deliberately not retained in the repository.

## Remaining gates

- Obtain additional authorized Sony body/firmware samples plus rollover, duplicate, missing-JPEG,
  orphan, and modified-timestamp cases before claiming compatibility beyond ILCE-1 v4.00.
- Persist the proven relationship after ingest and carry it through browser refresh,
  move/reject/archive, and source reassociation.
- Add Caption Workspace playback and explicit state presentation.
- Add local cancellable transcription, reviewed transcript persistence, and the shared
  `{voiceMemoTranscript}` variable path.
- Add explicit delivery include/exclude policy, preflight reporting, and receipt evidence.
- Run the manual real-card-to-caption and external workflow validation.
