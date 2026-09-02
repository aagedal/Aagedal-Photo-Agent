# Plan-status Browser and Compare presentation-facts continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Browser retina pre-caching and committed-source comparison no longer read XMP sidecars or image
headers synchronously from their MainActor owners. The audit remains at 66 of 75 completed substeps, with nine
remaining.

## Serialized presentation facts

Both workflows now reuse `FullScreenImagePresentationFactsService`, the serialized actor that freezes XMP Camera
Raw settings, sidecar orientation, embedded orientation, and pixel dimensions into one immutable result. The actor
samples cancellation before and after its non-preemptible Foundation/ImageIO read and distinguishes cancellation
before any read from cancellation observed after the snapshot was collected.

Browser retina pre-cache assigns every selection request a UUID, cancels replacement work, and validates both the
request identity and current one-image selection after the presentation-facts read and again after decode. An
A → B → A navigation therefore cannot let the first A request populate the cache after the newer A session has
started. Cache identity continues to include edit settings, display orientation, and original-versus-edited mode.

Compare resolves missing committed Camera Raw settings through the same actor before initial left/right renders
and source replacement. In-memory settings still bypass disk. Cancellation or a mismatched request/image result
fails closed, and replacement retains its existing comparison-session identity check before publication.

## Characterization and validation

Two new source-contract characterizations prove that:

- Browser retina pre-cache awaits the injected presentation-facts actor, performs no direct XMP/orientation read,
  and gates both read and decode completion by request identity plus current selection; and
- Compare awaits the shared serialized actor for committed settings, validates request and image identity, and no
  longer calls `XMPSidecarService.loadSidecar` from its MainActor render orchestration.

The complete presentation-facts suite passed 6 tests. The adjacent full-screen cache, comparison coordinator, and
full-screen shortcut selection passed 47 tests. `scripts/ci/validate_repository.sh` passed generated documentation,
release metadata, JSON, plist/project, provenance, privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,910 tests in 223 suites with zero failures in 64.068 seconds. Result
bundle: `build/AagedalPhotoAgent-PresentationFacts-2026-09-02.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
