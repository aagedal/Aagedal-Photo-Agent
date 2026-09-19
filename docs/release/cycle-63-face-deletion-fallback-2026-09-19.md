# Cycle 63 — Face deletion fallback and cleanup errors

State: IMPLEMENTING. Baseline `bb786f9`; checkout initially clean. This report describes
working-tree changes on that baseline.

## Implementation

Photo-based face deletion with no loaded face document now uses the shared admitted folder
loader. A competing photo or folder operation refuses before document reads, corrupt-file
recovery or thumbnail reads. The refusal is surfaced to the user; cancelled or superseded
requests cannot publish results or errors over a newer folder navigation.

A regression test exposed a second defect: equivalent folder URLs with and without a
trailing slash failed the deletion route's URL equality guard. The guard now compares
standardized paths, allowing the deletion to proceed for either serialized URL form.
Deletion preserves the other photo's faces and thumbnails and repairs group membership
and representative selection through the existing persistence path.

Failed expiration cleanup now surfaces the storage error while retaining the loaded face
results. Previously the service returned the failure but the view model silently ignored it.

## Verification

Focused validation passes **34 tests / 51 executions**, zero failures/skips/runtime warnings;
`build/qa-face-fallback-focused-4.xcresult`. Host: arm64 MacBook Pro, macOS 27.0 (26A428),
Debug test build. Complete serial validation passes **3,012 tests / 3,932 executions**,
zero failures/skips, in a 129.757-second test operation; `build/qa-face-fallback-full.xcresult`.
The four previously recorded QoS warnings remain in CaptionSessionTests and
MetadataEditorReadServiceTests. Repository validation passes;
`build/qa-face-fallback-repository-final.log`. New tests
cover photo/folder contention, cancellation by navigation, retry for both directory URL
forms, durable survivor/group/thumbnail preservation, and cleanup failure presentation.
The first executable focused run reproduced the folder-identity defect; it is corrected
in the final implementation. A subsequent fixture correction supplies the faces’ group IDs
to match their group membership; the final focused run passes. The initial sandboxed run
could not access compiler caches. Test startup also logged `MDB_MAP_FULL` diagnostics;
Xcode reported no test failures or runtime warnings in the successful focused run.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO -jobs 1`; focused selectors are ActivityHistoryTests and
FaceFolderLoadServiceTests. Repository validation uses `scripts/ci/validate_repository.sh`
and `git diff --check`. Fixtures use disposable temporary folders and synthetic documents.
No native interaction or supported-client evidence is claimed.

## Remaining release work

The fallback load and subsequent queued persistence hold separate reservations. Stale
in-memory face-data reconciliation across that interval and other interactive edits remains
open; this change does not claim a transaction spanning the entire read/edit/write cycle.
Remaining GUI writers, production MCP workflow tools, durable operation status/cancellation,
guarded IPTC prepare/commit, template/provider discovery and FFmpeg Whisper remain unfinished.
Native/accessibility, authentic camera/editor/transport, cloud, hardware/performance and
migration/recovery evidence, legal review, remote CI enforcement, exact-candidate packaging,
final acceptance and authorized distribution remain release gates.
