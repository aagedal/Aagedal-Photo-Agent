# Plan-status Known People import-commit continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Known People archive imports no longer write person records
or thumbnail files from the MainActor service. The audit remains at 66 of 75 completed substeps, with nine
remaining.

## Serialized destination commit

`KnownPeopleArchiveService` now accepts an immutable commit request containing the request identity, exact storage
root, duplicate-filtered people, and prepared thumbnail bytes. The actor writes person and embedding thumbnails
with the existing best-effort policy, then treats each coordinated person-file write as the durable per-person
commit boundary.

The result distinguishes complete, cancelled, and failed work and returns the exact committed person prefix,
person-file URLs, thumbnail URLs, and aggregate thumbnail-failure count. Cancellation is sampled before and after
every synchronous coordinated write. A cancellation or person-write failure after earlier commits therefore does
not imply that the batch rolled back.

`KnownPeopleService` validates request identity, storage root, requested count, and storage revision before
publication. It stamps every durable local write and installs the exact committed person prefix in the MainActor
database before surfacing cancellation or a later failure. A storage route change rejects late publication into
the replacement local/iCloud store.

A privacy-safe `OSSignposter` interval records only complete/cancelled/failed state and aggregate requested,
committed, thumbnail, and thumbnail-failure counts. It never records a path, filename, person identity, or image
content.

## Characterization and validation

A new failure-injection characterization cancels the operation from inside the first person-file write. It proves
the destination work executes away from MainActor, the second person is never accessed, and the result reports the
first person plus both already-written thumbnails as the exact durable prefix. Its source contract also proves the
production import entry point awaits the actor and contains no direct coordinated writes or `writePerson` loop.
The existing real ZIP export/import round trip continues to verify person identity and both thumbnail classes.

The focused `KnownPeopleServiceTests` suite passed all 16 tests. The adjacent Known People, iCloud-routing, and
startup-signpost selection passed all 44 tests across three suites. `scripts/ci/validate_repository.sh` passed
generated documentation, release metadata, JSON, plist/project, bundled component provenance, logger/investigation
privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,982 tests in 229 suites with zero failures in 58.989 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_19-39-25-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem/cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
