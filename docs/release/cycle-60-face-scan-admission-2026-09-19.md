# Cycle 60 — Face-scan folder admission

State: IMPLEMENTING. Baseline `3541b20`; checkout initially clean. Evidence tests that
baseline plus this cycle's working-tree changes on arm64 macOS 27.0 (26A428), Debug.

## Implementation

GUI face scans acquire the shared exclusive folder reservation off MainActor after pending
face-data persistence finishes, before loading or deleting the scan snapshot. The reservation
covers signature classification, detection, intermediate saves, final persistence and thumbnail
reload, including cancellation and failed final saves. It releases before completion is
published, with an idempotent deferred release covering early exits. Helper photo operations,
retained photo writes and Batch Rename using the same reservation cannot overlap this work.

A refused full scan reports the existing actionable busy error and leaves previous face results
and durable data intact. Presentation clearing now occurs only after admission and only if the
scanned folder is still displayed, so navigation during admission does not clear another folder.
No changes to automation preferences, model downloads or user photos are required.

## Verification

Disposable temporary folders and invalid image bytes exercise the production scan error path
without model inference. Added parameterized tests cover busy photo and folder admission,
full-scan preservation, reservation ownership during reads and final persistence, and release
after completion, immediate cancellation, injected persistence failure and no-op completion.
Existing rename-quiescence coverage verifies durable cancelled partial results before rename.

- Focused: **42 tests / 69 executions**, zero failures/skips or runtime warnings;
  `build/qa-face-admission-focused-2.xcresult` (4.970-second test operation).
- Repository checks pass: `build/qa-face-admission-repository.log`.
- Complete serial regression: **2,999 tests / 3,906 executions**, zero failures/skips;
  `build/qa-face-admission-full.xcresult` (136.775-second test operation). The same four
  previously recorded QoS warnings remain in CaptionSessionTests and MetadataEditorReadServiceTests.
- No new native interaction, real-client or hardware evidence is claimed.

The initial sandboxed Xcode invocation could not write compiler/package caches. The approved
invocation using normal Xcode caches passed. Reading the result summary also required approval
for Xcode's report cache.

## Remaining

This closes only the GUI face-scan execution reservation boundary. Other GUI file/face-data
writers and automation workflow tools, durable operation status/cancellation, guarded IPTC
patches, template/provider discovery and FFmpeg Whisper remain. The release also still needs
real-client/native/failure/accessibility/interoperability/hardware evidence, external legal/CI
gates, candidate packaging and final user acceptance. No broad Phase 5A gate is marked complete.

## Commands

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/ActivityHistoryTests' \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-face-admission-focused-2.xcresult -quiet
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-face-admission-full.xcresult -quiet
scripts/ci/validate_repository.sh
git diff --check
```
