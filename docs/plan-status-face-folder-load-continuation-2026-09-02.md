# Plan-status Face folder-load continuation — 2026-09-02

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary without claiming its remaining inventory or
measurement gates. Opening a folder no longer decodes `.face_data`, applies expiration cleanup, or reads face
thumbnail files synchronously from `FaceRecognitionViewModel` on the MainActor. The audit remains at 66 of 75
completed substeps, with nine remaining.

## Serialized immutable folder snapshots

`FaceDataFolderLoadService` is an injected actor that owns the complete folder-navigation read: face-document
decode, optional expiration deletion, representative-first thumbnail ordering, and every remaining face
thumbnail. It returns immutable bytes rather than AppKit image objects so `NSImage` construction and cache
ownership remain with the MainActor view model.

Cancellation is sampled before and after every non-preemptible document or thumbnail read. Cancelled evidence
contains the requested count and exact fully processed prefix, and callers never publish it as a complete folder
snapshot. Expiration deletion is different because it is a durable mutation: if cancellation arrives after the
delete commits, complete evidence records that outcome instead of pretending the old data remains. Deletion
failures are also explicit while retaining the readable snapshot.

`FaceRecognitionViewModel` cancels replacement work, assigns each load a request identity, clears the prior
folder's presentation immediately, and publishes only when both the request and displayed folder are current.
`thumbnailImage(for:)` is now a cache-only render lookup, eliminating disk reads from SwiftUI view evaluation.
During a scan, newly persisted thumbnail bytes are installed directly in the cache, and the committed final or
partial snapshot is refreshed through the same serialized load boundary.

## Characterization and validation

Six new tests prove that:

- document and complete all-face thumbnail reads happen off the main thread;
- cancellation after a thumbnail read returns the exact completed prefix;
- overlapping loads are serialized by the actor;
- cancellation after expired-data deletion reports the durable commit;
- a replacement folder rejects the blocked prior result while the MainActor stays available; and
- source contracts keep navigation reads behind the actor and rendering cache-only.

The focused six-test suite and the adjacent 33-test selection covering face loading, embeddings and on-demand
runtime behavior, activity history, and face-group deletion passed with zero failures.

`scripts/ci/validate_repository.sh` passed generated metadata, release metadata, JSON, plist/project,
provenance, privacy, conflict-marker, and whitespace checks. The serial unfiltered Xcode gate passed all 1,896
tests in 223 suites with zero failures in 62.698 seconds.

## Remaining boundary after this session

Phase 3.1 still needs remaining face-data persistence and mutation calls, the other lower-priority direct
filesystem paths, and real local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library,
signpost, and Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR Instruments
benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review,
real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted
release candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-
corrupt-download drills.
