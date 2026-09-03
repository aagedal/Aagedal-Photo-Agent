# Plan-status Clean Feed browse-render continuation — 2026-09-03

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Passive Clean Feed rendering no longer owns an ad hoc
detached RAW/ImageIO pipeline inside the SwiftUI view. The audit remains at 66 of 75 completed substeps, with
nine remaining.

## Actor-owned browse rendering

`CleanFeedBrowseRenderService` receives one immutable request containing request identity, image identity,
in-memory edit settings, display orientation, and output size. It resolves the adjacent ImageIO header through
the existing serialized presentation-facts actor, keeps HDR and downsample fallback work on the established
utility-QoS boundaries, applies committed edits away from MainActor, and returns one immutable image snapshot.

Passive RAW demosaicing now reuses `DevelopSourceDecodeService` instead of establishing an independent
`CIRAWFilter` path. The new draft-preview entry point shares Develop's serialized RAW executor and preserves the
existing screen-resolution clamp, flat-RAW EDR marker, crop-before-display-rotation order, and embedded-preview
fallback.

The service distinguishes cancellation before source work from cancellation observed after a non-preemptible
render. Its privacy-safe signpost records only ready, unavailable, or cancellation stage; it never records a path
or filename.

## Publication lifetime

`CleanFeedContentView` rotates a request identity for every selected image/settings/orientation reload. It
validates request identity, image identity, current Browser selection, complete service evidence, and current
browse-mode ownership before publishing. Entering Develop mode or removing the Clean Feed view cancels and
invalidates browse work, so a late passive render cannot overwrite the live Develop feed or a newer A → B → A
selection.

## Characterization and validation

Four new service/view characterizations prove off-MainActor execution, immutable request evidence, pre-render
cancellation with no source access, post-render cancellation evidence, view delegation, and stale-publication
guards. A fifth characterization proves passive RAW requests use draft mode on the shared serialized decoder.

The adjacent Clean Feed browse render, Develop source decode, full-screen presentation-facts, Develop Clean Feed
publication, and Comparison coordinator selection passed all 48 tests in five suites.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, logger and investigation privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,932 logical tests in 226 suites, representing 2,059 expanded
device/configuration executions, with zero failures in 62.179 seconds. Result bundle:
`build/AagedalPhotoAgent-CleanFeedBrowse-2026-09-03.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
