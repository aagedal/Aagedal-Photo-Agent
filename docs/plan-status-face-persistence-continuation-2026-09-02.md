# Plan-status Face persistence continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Face-data document reads, scan writes, interactive mutations, thumbnail reads/writes/cleanup,
and whole-folder deletion now cross one shared serialized actor instead of reaching `FaceDataStorageService`
directly from application owners. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Shared serialized face-data boundary

`FaceDataFolderLoadService` now owns document-only reads, complete folder snapshots, individual thumbnail reads,
thumbnail and document commits, orphan-thumbnail cleanup, and whole-folder deletion. Application call sites use
the shared actor; injected instances preserve deterministic test isolation.

Persistence returns immutable evidence that distinguishes cancellation before a document commit from
cancellation after durability. Face documents commit before orphan thumbnails are removed, so interruption can
leave only harmless unreferenced thumbnails rather than a document pointing to files already deleted. Cleanup
failures retain the exact successful thumbnail prefix. Scan thumbnail writes and periodic/final document saves use
the same actor, and a cancelled scan still performs its required final partial commit before rename quiescence
returns.

`FaceRecognitionViewModel` keeps interactive mutations UI-immediate while an ordered task chain submits immutable
revisions to the actor. Its explicit wait boundary lets async workflows and tests drain the latest durable write.
Group naming, representatives, lenses, Known People merges, Sports claims, grouping operations, individual/group
deletion, and Remove Face Data no longer perform Foundation filesystem work on MainActor.

Document-only consumers in Caption, metadata-variable resolution, FTP metadata preflight, Batch Rename
reassociation, and secondary-lens prewarming now use the same actor. Direct `FaceDataStorageService()` construction
is confined to the serialized service implementation.

## Characterization and validation

Seven new tests prove that:

- document-only reads return existence evidence off MainActor;
- document commits precede orphan-thumbnail cleanup off MainActor;
- cancellation after a non-preemptible document write reports the durable commit and does not start cleanup;
- view-model mutations publish immediately while their writer is blocked off MainActor;
- rapid mutations persist in visible revision order;
- interactive and scan paths cannot regain direct storage calls; and
- Caption, metadata, FTP, rename, and lens call sites cannot construct the synchronous storage service directly.

The integrated face, deletion, Batch Rename, Sports, and Caption selection passed 68 tests with zero failures.
`scripts/ci/validate_repository.sh` passed generated documentation, release metadata, JSON, plist/project,
provenance, privacy, conflict-marker, and whitespace checks.

The first serial unfiltered run exposed an existing rename-quiescence contract that the initial scan-preparation
implementation had weakened: immediate cancellation could return before writing a partial face snapshot. Scan
preparation is now detached from later scan cancellation, preserving its stable starting snapshot and final
partial commit. The five-test Activity History suite then passed, and the final serial unfiltered run passed all
1,903 logical tests (2,030 expanded executions) with zero failures, skips, or expected failures in 61.139 seconds.
Result bundle:
`Test-Aagedal Photo Agent Tests-2026.09.02_21-29-04-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem paths and real local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker evidence. Phase 3.2
still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
