# Plan-status AuraFace component-probe continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Launching the Known People UI no longer verifies the downloaded AuraFace descriptor, enumerates
the model package, reads its files, or hashes its contents synchronously from the MainActor. The audit remains at
66 of 75 completed substeps, with nine remaining.

## Serialized component resolution

`AuraFaceComponentProbeService` owns one complete installed-or-bundled resolution transaction. The actor verifies
the signed downloaded descriptor and declared package file set once, resolves the compiled model URL, and returns
one immutable `AuraFaceComponentResolution`. Cancellation is sampled before and after the synchronous resolver, so
a cancelled verification never publishes its result, and overlapping requests cannot interleave their filesystem
work.

`AuraFaceComponentManager` starts in an explicit Checking state, cancels replacement work, assigns each request an
identity, and publishes only the current complete resolution. Download and removal now re-enter the same probe
before changing visible availability. A completed download must resolve as the verified downloaded component or it
fails closed. The face bar presents a progress state while this initial check is pending instead of briefly
claiming that the model is unavailable.

`CoreMLFaceEmbedder.shared` no longer resolves or reverifies the component during its MainActor-triggered lazy
initialization or cache refresh. It accepts only a pre-resolved URL through a lock-only publication method, clears
the old Core ML cache at that boundary, and exposes Checking until the first serialized resolution completes.
Known People embedding migration consults this cached verified availability rather than starting a second package
verification from its MainActor load path.

## Characterization and validation

Two new tests prove that:

- the dynamic embedder moves from Checking to available or unavailable using only a pre-resolved URL; and
- a blocked component probe runs away from the main thread, keeps overlapping probes serialized, and rejects the
  cancelled first result after a replacement request.

The focused `FaceEmbeddingTests` suite passed. The adjacent Face folder-load, face-group deletion, Known People,
and activity-history selection also passed with zero failures. `scripts/ci/validate_repository.sh` passed generated
documentation, release metadata, JSON, plist/project, provenance, privacy, conflict-marker, and whitespace checks.

The final serial unfiltered run passed all 1,908 logical tests and 2,035 expanded device/configuration executions,
with zero failures, skips, or expected failures in 63.910 seconds. Thirty-six parameterized tests produced 163
runs. Result bundle: `AagedalPhotoAgent-AuraFaceProbe-Final.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths plus real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
