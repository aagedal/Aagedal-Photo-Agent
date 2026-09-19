# Cycle 62 — Face folder-load admission

State: IMPLEMENTING. Baseline `d47be7a`; checkout initially clean. Changes and validation
are local working-tree changes on top of that baseline.

## Implementation

Interactive folder loading now acquires the shared exclusive folder reservation before
reading the face document. It retains ownership through corrupt-document relocation,
expiration deletion and every thumbnail read. Competing photo/folder operations refuse
before the loader runs. Scan preparation and final refresh retain their existing enclosing
scan reservation without nested admission.

Document-only consumers now use a non-mutating decode path: invalid bytes remain in place,
with document-existence and failed-decode evidence available to rename preparation. Opening
the folder with admission still relocates corrupt bytes into the existing recovery file.
This avoids adding nested folder reservations to metadata-variable or rename operations.

Same-folder reload refusal retains displayed results and surfaces the busy error. Navigating
to another folder still clears the preceding folder's presentation; request identity prevents
superseded completions or errors from being installed.

## Verification

New regressions cover photo and folder contention before loader callbacks, admission during
cleanup and thumbnail reads, cancellation before work/after read/after committed deletion,
cleanup failure and lease release, actual corrupt-document byte preservation and admitted
relocation, and view-model refusal plus expiration retry. Existing scan, folder-load and
rename coverage checks the surrounding behavior.

- Focused suite: **49 tests / 64 executions**, zero failures/skips/runtime warnings;
  `build/qa-face-load-focused-4.xcresult`.
- Repository validation passes: `build/qa-face-load-repository.log`.
- Complete serial suite: **3,008 tests / 3,926 executions**, zero failures/skips;
  `build/qa-face-load-full.xcresult`, 132.895-second test operation. Four previously recorded
  QoS warnings remain in CaptionSessionTests and MetadataEditorReadServiceTests.
- Host: arm64 MacBook Pro, macOS 27.0 (26A428), Debug test build.
- No native GUI or supported MCP-client validation is claimed by this cycle.

The initial sandboxed attempt could not write compiler/package caches. The first approved
attempt reported a Swift compiler task failure with exit code zero and no diagnostic. Retry
compiled and exposed the existing scan-admission fixture taking its competing reservation
before loading its initial results. The fixture now loads first, then holds the reservation
while verifying that a refused full rescan preserves those results. The final focused run passes.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO -jobs 1`. Focused selectors are ActivityHistoryTests,
FaceFolderLoadServiceTests and BatchRenameSheetStateTests. Repository validation uses
`scripts/ci/validate_repository.sh` and `git diff --check`.

## Remaining release work

Cross-process stale in-memory face-data reconciliation and remaining GUI writers remain open.
Production MCP workflow tools, durable operation status/cancellation, guarded IPTC prepare/commit,
template/provider discovery and the FFmpeg Whisper provider remain unfinished. Required native,
accessibility, authentic-camera, delivery, cloud, external-editor, hardware/performance and
migration/recovery evidence remains open, together with external legal/remote-CI requirements,
exact candidate packaging, final acceptance and authorized distribution.
