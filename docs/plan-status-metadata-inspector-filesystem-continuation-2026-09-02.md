# Plan-status Metadata inspector filesystem continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. The Raw Metadata XMP tab and the technical-metadata inspector no longer start ad hoc detached
filesystem/header reads from MainActor-owned views. The audit remains at 66 of 75 completed substeps, with nine
remaining.

## Serialized XMP sidecar snapshot

`RawMetadataXMPSidecarLoadService` now owns sidecar existence, byte loading, and pretty-printed XML production on
one serialized actor. One immutable result carries the request identity, image identity, and either the complete
sidecar snapshot, an explicit not-found outcome, or cancellation. Cancellation is sampled before and after the
non-preemptible Foundation read.

`RawMetadataView` rotates a UUID for each XMP-tab request, cancels replacement work, and invalidates the request on
disappearance. It validates both request and image identity before publishing found or not-found state, so an
A → B → A selection sequence cannot let the first A request overwrite the newer A session.

## Serialized technical-metadata fast path

`TechnicalMetadataFastLoadService` now owns the complete `TechnicalMetadata.fromImageIO` fast path. ImageIO header
reads and the adjacent file-modification stat execute away from MainActor and return one immutable request/image-
keyed snapshot. Cancellation is explicit both before the read and after the synchronous snapshot completes.

`ContentView` validates request identity, selected URL, and snapshot identity before publishing the fast result. It
repeats those guards around the optional SwiftExif enrichment and cache publication, closing the same A → B → A
race for both the initial inspector contents and the enriched result.

## Characterization and validation

Eight new tests prove that both actor boundaries execute their synchronous access away from MainActor, preserve
immutable request/image identity, avoid starting a read when already cancelled, report cancellation observed after
a non-preemptible read, and keep the view owners on the injected boundary. The focused actor selection passed 12
tests, including the four existing app-sidecar cases. The adjacent technical-metadata and sidecar selection passed
73 tests.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,922 tests in 225 suites with zero failures in 65.284 seconds. Result
bundle: `build/AagedalPhotoAgent-MetadataUIReads-Final-2026-09-02.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
