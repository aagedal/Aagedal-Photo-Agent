# Cycle 66 — Individual face deletion reconciliation

State: IMPLEMENTING. Baseline `5690801`; checkout initially clean.

## Implementation

Individual face-ID deletion now shares the reserved read/edit/write transaction used by
photo-URL deletion. The selection is applied to the latest disk document, preserving newer
group names and added faces, including other faces in the same photo. Unknown and already
removed IDs are harmless. Group membership and representative faces are repaired from the
disk snapshot; thumbnail cleanup follows a successful document commit.

The shared view-model queue retains visible results on busy admission or failed save,
serializes consecutive deletions, and guards publication with request/model revisions.
The existing deletion-generation protection now also prevents a queued whole-document
edit from restoring individually deleted faces. Reload/reapply remains the explicit
recovery for stale local edits. Face-only group UI actions that call `deleteFaces` inherit
this behavior; the separate `deleteGroup` photo-trash workflow is not covered.

## Verification

Regression coverage extends the external-edit, busy, queued-deletion, overlapping-edit
and write-failure cases to the individual-ID path. A separate same-photo test verifies
that deleting one face preserves its peer, repairs the group representative, retains the
peer thumbnail, and tolerates unknown/repeated IDs.

Focused validation passes **25 tests**, zero failures or skips:
`build/qa-face-id-deletion-focused-2.xcresult`.
The complete final-source suite passes **3,017 tests across 319 suites**, zero failures or
skips, in 119.841 seconds: `build/qa-face-id-deletion-full.xcresult`.
The same four previously recorded QoS warnings remain in CaptionSessionTests and
MetadataEditorReadServiceTests. The test host also logs `MDB_MAP_FULL` diagnostics.

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Debug app 3.0.0 build 739.
Both runs use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO -jobs 1`; the focused run adds
`-only-testing:'Aagedal Photo Agent Tests/ActivityHistoryTests'`.
Tested source is baseline `5690801` plus this cycle's three Swift file changes;
subsequent edits affect documentation only.

Repository validation passes (`build/qa-face-id-deletion-repository.log`). The first sandboxed Xcode attempt
failed because compiler-cache writes were denied; authorized execution uses the standard
macOS test host. Fixtures are synthetic temporary folders; no user photos or preferences
are changed. Native UI evidence is not claimed.

## Remaining before release

General cross-process stale-save detection, other whole-document face edits and the
separate group/photo-trash workflow still need reconciliation. Production MCP workflow
tools, operation status/cancellation, guarded IPTC commits, template integration and
FFmpeg Whisper remain unfinished. Required native/accessibility, authentic camera/editor/
transport, cloud, hardware/performance and migration/recovery evidence remains open,
as do qualified privacy/legal review, remote CI enforcement, exact-candidate packaging,
independent release review, final user acceptance and authorized signed distribution.
