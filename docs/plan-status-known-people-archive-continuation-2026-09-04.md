# Plan-status Known People archive continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Known People ZIP preparation no longer performs archive
filesystem work from the MainActor service. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized archive preparation

`KnownPeopleArchiveService` now exclusively serializes export and import preparation across the asynchronous
`ditto` phase. Export creates and cleans its temporary tree, encodes manifest and people data, reads coordinated
person and embedding thumbnails, writes the local staging files, and invokes `ditto` from the actor. Import runs
`ditto`, discovers the extracted root, validates and decodes `people.json`, and loads all available thumbnail bytes
before returning one immutable `KnownPeopleArchiveImportPayload`.

The actor samples cancellation before and after archive commands and around every synchronous file or coordinated
iCloud read. A cancelled queued request therefore performs no file access, while cancellation following a
non-preemptible command is surfaced before publication. Temporary directories remain actor-owned and are cleaned
up on every exit path.

## MainActor publication boundary

`KnownPeopleService` now gives export an immutable people snapshot and resolved thumbnail roots, and awaits only
the archive actor. Import captures the storage revision before preparation and rejects the payload if local/iCloud
routing changes while extraction is underway. Duplicate filtering, destination persistence, self-write stamping,
and in-memory database publication remain together on MainActor so the existing per-person state transaction is
preserved.

## Characterization and validation

A new injected file-access characterization proves import archive access runs off MainActor, returns immutable
person/thumbnail bytes, and honors cancellation before any second access. A second test performs a real `ditto`
export/import round trip and verifies person identity plus both person and embedding thumbnail bytes. The focused
Known People suite passed all 15 tests. The repository validation gate passed generated documentation, release
metadata, JSON, plist/project, bundled component provenance, logger/investigation privacy, conflict-marker, and
whitespace checks.

The final serial unfiltered run passed all 1,981 tests in 229 suites with zero failures in 69.428 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_19-23-47-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs import destination commits and the remaining lower-priority direct filesystem/cached-model
paths, plus real local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and
Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
