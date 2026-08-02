# Phase 5 OSINT timeline slice — validation

## Implemented

- Added timestamp evidence with explicit capture, GPS, file-created, file-modified,
  sidecar-modified, and investigator-observation kinds.
- Preserved evidence source and precision independently from the timestamp value.
- Stored wall-clock date components directly, with an optional UTC offset. Metadata without a
  timezone therefore remains timezone-unknown and cannot silently become an absolute instant.
- Derived stable timeline rows from persisted source facts for embedded capture, GPS, file-system,
  and XMP-sidecar timestamps.
- Added case-only user observations with day or minute precision and an explicit choice to apply
  the Mac's current timezone.
- Bumped `AnalysisCase` to schema version 5. Versions 1–4 migrate with an empty user-entered
  timestamp collection while preserving their existing analyzer and annotation data.
- Added validation for calendar dates, precision, UTC-offset range, duplicate IDs, source type,
  titles, provenance detail, and update times.
- Added an OSINT timeline that displays the timestamp source, precision, timezone-known state, and
  provenance detail on every row.
- Added conflict derivation for differing timezone-qualified capture/GPS times and capture times
  occurring after the source file's modification time. Timezone-unknown values are excluded from
  absolute-time comparisons.
- Kept add/delete controls read-only for source-changed cases. User observations persist in the
  analysis JSON only and do not write IPTC, XMP, or source bytes.

## Automated validation

Command:

```sh
xcodebuild test \
  -scheme "Aagedal Photo Agent Tests" \
  -destination "platform=macOS" \
  -only-testing:"Aagedal Photo Agent Tests/AnalysisCaseTests"
```

Result: 33 tests passed in 1 suite.

Timeline-specific coverage includes:

- version 4 to version 5 migration with markup preservation;
- user-observation atomic persistence and unchanged source bytes;
- invalid calendar dates, UTC offsets, and non-user entries in the persisted user collection;
- explicit timezone-unknown capture representation without a fabricated instant;
- source/precision labels for derived file-system evidence and paired GPS date/time parsing; and
- conflict detection between differing timezone-qualified capture and GPS timestamps.

## Remaining Phase 5 work

- Reuse coordinate parsing, place search, and reverse-geocoding patterns.
- Add persisted satellite/hybrid map viewport state and map annotations.
- Link photo and map annotations by stable label ID.
- Add offline/network/no-imagery states and attribution-compliant report evidence.
- Decide the conditional sun/shadow analyzer gate.
