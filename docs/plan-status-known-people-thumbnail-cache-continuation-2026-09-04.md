# Plan-status Known People thumbnail cache continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Known People person and embedding thumbnails no longer
perform coordinated filesystem reads from synchronous SwiftUI presentation or the MainActor service. The audit
remains at 66 of 75 completed substeps, with nine remaining.

## Serialized thumbnail reads

`KnownPeopleThumbnailLoadService` now owns coordinated JPEG reads on one actor and returns immutable data plus
request identity. It samples cancellation before and after the non-preemptible coordinated read and records a
privacy-safe signpost outcome. `KnownPeopleService` resolves the current local/iCloud root asynchronously, rejects
results from an obsolete storage revision, decodes complete data on MainActor, and publishes bounded person and
embedding image caches.

Storage switches, database resets, deletes, and remote thumbnail events invalidate the affected caches. Remote
events also advance the storage revision so a read that began against older contents cannot republish them.
Thumbnail writes publish their already-available bytes directly into the cache.

## Async presentation and export

Known People lists, detail and edit cards, embedding grids, face-management suggestions, replacement previews,
and linked team-roster faces now load through identity-bound SwiftUI tasks and reject cancelled or stale results.
Changing or removing the representative embedding preloads any required replacement image before mutating the
record, preserving the existing person-thumbnail update without a MainActor disk read. Roster PDF export preloads
each distinct linked person asynchronously, then gives the synchronous renderer an in-memory lookup.

## Characterization and validation

Two new characterizations prove that thumbnail data is read off MainActor with explicit pre-read cancellation and
that synchronous presentation access remains cache-only across the affected views. The focused Known People,
iCloud-routing, and roster-export selection passed all 43 tests. The repository validation gate passed generated
documentation, release metadata, JSON, plist/project, bundled component provenance, logger/investigation privacy,
conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,979 tests in 229 suites with zero failures in 62.919 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_18-30-02-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
