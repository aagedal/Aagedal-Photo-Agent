# Cycle 68 — Guarded interactive face-data saves

State: IMPLEMENTING. Baseline `9e41502`; checkout initially clean.

## Implementation

All queued interactive whole-document face edits now pass their editor's last loaded or
successfully committed snapshot into the reserved storage transaction. The service reads
without corrupt-file recovery and compares canonical encodings of the typed documents before
writing. Changed, removed, corrupt or foreign-folder data refuses the save before document
or thumbnail mutation, with reload/reapply guidance. This covers the common persistence
boundary used by naming, manual numbers, grouping, representative faces and sports edits.

Each view model owns its authority, so another editor using the shared storage actor cannot
refresh a stale editor's baseline. Ordered rapid edits advance only after successful commits;
busy admission and failed writes retain the earlier authority for retry. Folder reloads
replace the retained snapshot cache and advance the queue generation. Scan completion and
transactional deletions also refresh authority; existing generation checks keep superseded
queued edits from restoring old state. The UI continues to show immediate local edits and
reports refusal; conflict resolution requires reload and explicit reapplication.

This is conflict refusal, not an automatic merge. Comparison covers the persisted typed
model, not arbitrary unknown JSON extensions. The reservation coordinates participating
Photo Agent processes; it cannot make an unrelated writer honor the lease. Other writer
routes and complete GUI/MCP operation ownership remain separate release work.

## Verification

Temporary-folder regressions verify changed/deleted/corrupt/foreign documents remain intact,
thumbnail retention, reservation ownership during comparison, lease release after refusal,
independent editor baselines, reload/reapply, ordered edits, and retry after busy admission
or a failed save. Existing deletion and off-main-actor persistence tests remain included.
The synthetic persistence and Reset to Unnamed tests now use actual temporary documents
so their loaders and writers exercise coherent storage state. Reset also verifies the
durable name, identity, face membership and representative face after the UI command.

The focused checkpoint passes **49 tests in three suites**, zero failures:
`build/qa-face-save-baseline-focused-2.xcresult`. The first integrated run had one failure
in the older Reset to Unnamed fixture, whose injected writer had no corresponding saved
document. Correcting the fixture passes **11 tests in one suite**:
`build/qa-face-save-reset-focused.xcresult`. The final integrated suite passes **3,024 tests
across 319 suites**, zero failures, in 122.434 seconds:
`build/qa-face-save-baseline-full-2.xcresult`. Final repository validation passes
(`build/qa-face-save-baseline-repository-final.log`). Seven Thread Performance Checker
QoS diagnostics remain unresolved release observations.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-face-save-baseline-full-2.xcresult
scripts/ci/validate_repository.sh
```

The focused selection uses `ActivityHistoryTests`, `FaceFolderLoadServiceTests` and
`FaceGroupDeletionTests` under target `Aagedal Photo Agent Tests`. Host: arm64,
macOS 27.0 (26A428), Debug app 3.0.0 build 739, in Xcode's
`Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug` DerivedData
directory. Tested source: baseline plus this cycle's four Swift files. The initial sandboxed command could not write compiler caches;
authorized Xcode execution built and ran the tests. Test-host `MDB_MAP_FULL` messages
remain observed diagnostics. No native UI or real-photo workflow evidence is claimed.

## Remaining before release

Production MCP workflow tools, operation status/cancellation, guarded IPTC commits,
template integration and FFmpeg Whisper remain unfinished. Broader writer admission,
authentic camera/editor/transport interoperability, native/accessibility, cloud,
hardware/performance and migration/recovery evidence remain open. Qualified privacy/legal
review, remote CI enforcement, exact-candidate packaging, independent release review,
final user acceptance and authorized signed distribution are still required.
