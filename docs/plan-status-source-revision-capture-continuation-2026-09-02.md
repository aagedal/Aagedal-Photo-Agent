# Plan-status Source revision capture continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Source-revision capture now moves canonical-path resolution, both resource-value probes, and
streamed SHA-256 hashing off MainActor callers and through one shared serialized actor. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Serialized stat-hash-stat boundary

`SourceImageRevision.capture` now delegates the complete canonicalize, stat, hash, stat, and immutable-result
transaction to `SourceImageRevisionCaptureService`. The actor method contains no suspension point, so one capture
remains contiguous and overlapping requests cannot interleave their filesystem stages. Existing Analysis,
comparison, Develop-version, Deadline, and delivery-staging callers inherit the boundary without changing their
revision identity or source-change detection semantics.

`HashStream` exposes its existing chunked implementation as a synchronous core for serialized filesystem actors.
The public async entry point retains its behavior, while the source-revision actor can keep the entire transaction
non-reentrant. Cancellation is sampled before filesystem access, after canonicalization, after each resource probe,
and after hashing; the streaming hash also continues to sample cancellation between chunks. Cancellation never
publishes a partial revision and performs no mutation.

The actor accepts immutable injectable filesystem primitives. This creates a deterministic seam for slow-volume,
ordering, thread, and cancellation characterizations without weakening the production URL-resource and SHA-256
implementation.

## Characterization and validation

Three new tests prove that:

- canonicalization, both stat probes, and hashing execute away from MainActor;
- cancellation observed after a non-preemptible stat stops before hashing; and
- overlapping requests complete as two serialized stat-hash-stat transactions.

The focused `SourceImageRevisionTests` suite passed 10 tests. The integrated source-discovery, Analysis,
comparison, Develop-version, and delivery-staging selection passed 151 tests across seven suites. The final serial
unfiltered run passed all 1,906 tests in 223 suites with zero failures in 62.157 seconds. Result bundle:
`Test-Aagedal Photo Agent Tests-2026.09.02_22-07-36-+0200.xcresult`.

`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, privacy, conflict-marker, and whitespace checks.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths, including synchronous path-projection
and cached-model probes, plus real local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library,
signpost, and Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR Instruments
benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
