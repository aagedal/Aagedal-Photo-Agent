# Cycle 67 — Reserved group and photo deletion

State: IMPLEMENTING. Baseline `3ee53cf`; checkout initially clean.

## Implementation

`deleteGroup` now joins the face-data persistence queue and reserves the folder before
reading its current document or moving any photos to Trash. The reservation remains held
through document persistence and thumbnail cleanup. The confirmed face IDs are reconciled
against the latest document, preserving externally added faces and group edits. A changed
photo URL or foreign-folder document refuses the operation before Trash.

The existing partial-Trash contract remains explicit: once photos are attempted, the
confirmed face selection is removed even if a photo move fails, provided the face-data
commit succeeds. Completed photo moves are never rolled back or hidden if the subsequent
face-data save fails. Save failure preserves visible faces and thumbnails and returns a
separate failure disposition with the completed-photo evidence for the existing details UI.
Thumbnail-cleanup failure after commit publishes the committed document and reports the
cleanup problem. Cancellation propagates to the worker and is distinguished from success.

Committed group deletions advance the same generation used by individual deletion, so
queued stale whole-document edits cannot restore removed faces. Navigation or a newer local
model prevents stale presentation publication. Reload/reapply remains necessary for stale
local edits. This is not general cross-process reconciliation for other face mutation routes.

## Verification

Synthetic temporary-folder regressions cover partial Trash success, stale presentation,
pre-cancellation, held folder/photo admission during Trash, busy refusal and retry,
external additions and renames, failed saves, queued stale edits, and changed photo identity.
The existing Activity History and Trash feedback suites are included in focused validation.

Focused validation passes **61 tests in three suites**, zero failures:
`build/qa-group-deletion-focused-3.xcresult`. The complete suite passes **3,022 tests
across 319 suites**, zero failures, in 124.485 seconds:
`build/qa-group-deletion-full.xcresult`. Seven Thread Performance Checker QoS diagnostics
appear in metadata/review tests; these remain unresolved release observations.
Repository validation passes (`build/qa-group-deletion-repository.log`).

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-group-deletion-full.xcresult
scripts/ci/validate_repository.sh
```

The focused command uses the same flags with `-only-testing` for `FaceGroupDeletionTests`,
`ActivityHistoryTests`, and `DevelopInteractionBehaviorTests`, under target
`Aagedal Photo Agent Tests`. Host: arm64, macOS 27.0 (26A428), Debug app 3.0.0 build 739,
in Xcode's `Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug`
DerivedData directory. Tested source: baseline plus this cycle's five Swift files; later
edits are documentation only.

The first sandboxed attempt could not write compiler caches. Authorized Xcode execution
then found an exhaustive test switch needing the new failure case; that was corrected
before the passing run. Existing test-source warnings include redundant `#require` and
an end-of-scope `defer`. The test host logs `MDB_MAP_FULL` diagnostics.
No native UI or real-photo Trash validation is claimed. No user photos or preferences
are intentionally changed.

## Remaining before release

Other whole-document face edits still need cross-process stale-save protection. Production
MCP workflow tools, operation status/cancellation, guarded IPTC commits, template integration
and FFmpeg Whisper remain unfinished. Native/accessibility, authentic camera/editor/transport,
cloud, hardware/performance and migration/recovery evidence remains open, as do qualified
privacy/legal review, remote CI enforcement, exact-candidate packaging, independent release
review, final user acceptance and authorized signed distribution.
