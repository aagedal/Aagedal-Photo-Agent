# Cycle 65 — Loaded photo-face deletion reconciliation

State: IMPLEMENTING. Baseline `56ea553`; checkout initially clean.

## Implementation

Photo-based face deletion now uses the reserved read/edit/write transaction for loaded
folders as well as lazy folders. It removes faces from the latest disk document, retaining
external group renames, newly added faces and surviving thumbnails. Busy admission preserves
visible results. Save failure presents the original disk snapshot and an error. Mixed-folder
requests are refused before work is scheduled.

Loaded deletion requests queue in order and join the persistence barrier. Request tokens and
model revisions prevent an obsolete result from replacing newer presentation. A per-folder
deletion generation refuses whole-document edits captured before a queued deletion commits;
those stale snapshots remain blocked until a fresh folder load (or successful transactional
snapshot publication). The error explicitly asks the user to reload and reapply the unsaved
edit. This prevents a subsequent local save from resurrecting the removed faces.

## Verification

Regression cases cover external changes, admission contention, consecutive queued deletions,
overlapping local edits, repeated stale-save refusal, reload/reapply recovery, and save failure
with and without an already-loaded document. Existing transactional cancellation, thumbnail
cleanup and navigation coverage remains in the focused Activity History suite.

Final focused validation passes **24 tests / 49 executions**, zero failures, skips or
runtime warnings: `build/qa-loaded-face-deletion-focused-4.xcresult`. The earlier expanded
run exposed the repeated-edit retry loophole; the final run verifies persistent refusal and
reload/reapply recovery. A final source comment changed after this focused compilation;
the integrated run below rebuilds the exact final source.

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Debug app 3.0.0 build 739.
Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO -jobs 1`, with the focused selector
`-only-testing:'Aagedal Photo Agent Tests/ActivityHistoryTests'`.
The initial sandboxed run could not access compiler caches; authorized execution succeeded.
Xcode reports no focused runtime warnings, although the launch log contains three
`MDB_MAP_FULL` diagnostics. No assertion failed in the final focused run.

Repository validation passes (`build/qa-loaded-face-deletion-repository-final.log`).
Test fixtures are synthetic temporary folders; no user photos or preferences are changed.
Native UI evidence is not claimed.

Complete final-source serial validation passes **3,016 tests / 3,944 executions** across
319 suites, zero failures or skips: `build/qa-loaded-face-deletion-full.xcresult`.
Swift Testing reports 116.986 seconds. The same four previously recorded QoS warnings
remain in CaptionSessionTests and MetadataEditorReadServiceTests; startup also logs
`MDB_MAP_FULL` diagnostics. No new runtime warning is reported for this slice.

## Remaining scope

This closes photo-URL deletion reconciliation only. Individual face-ID deletion, group deletion,
other interactive whole-document edits and cross-process stale-save detection still need a
shared optimistic concurrency or transactional mutation design. The local deletion generation
is process-local and is not general cross-process conflict detection.

Production MCP workflow tools, status/cancellation, guarded IPTC commits, template/provider
integration and FFmpeg Whisper remain open. Native/accessibility, authentic camera/editor/
transport, cloud, hardware/performance, migration/recovery, legal review, remote CI enforcement,
exact-candidate packaging, final acceptance and authorized distribution remain release gates.
