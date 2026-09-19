# Cycle 61 — Interactive face-data admission

State: IMPLEMENTING. Baseline `52f1c56`; checkout initially clean. Validation uses
that baseline plus this cycle's changes on arm64 macOS 27.0 (26A428), Debug.

## Implementation

Queued interactive face-data saves now acquire the shared exclusive folder reservation
on the serialized filesystem executor before writing the document. The lease lasts through
orphan-thumbnail cleanup and releases on success, storage failure and cancellation.
Explicit whole-folder face-data deletion uses the same boundary. A competing photo or folder
operation refuses before storage callbacks run and returns the existing actionable busy error.
Scan-owned persistence retains its enclosing scan lease without attempting nested admission.

Deletion no longer clears visible results before disk success. A busy or failed deletion retains
those results for retry. Success clears the presentation only when the same folder and face-data
revision remain displayed. Cancelling an outstanding load prevents a pre-deletion snapshot from
being published afterwards. Navigation to another folder is preserved.

Group edits retain their existing immediate in-memory presentation; admission failure reports
that saving failed, preserves durable bytes and permits an explicit retry. This does not add
cross-process stale-snapshot reconciliation or automatic retry of rejected edits.

## Verification

Tests use disposable temporary folders and injected storage callbacks. They cover competing
photo/folder leases, refusal before document/thumbnail/deletion writes, ownership throughout
commit and cleanup, storage/cleanup failures, cancellation before and after document commit,
lease release, actual group-edit refusal/retry, deletion refusal/retry, and navigation during
pending deletion. Existing scan tests verify scan-owned persistence still succeeds.

- Focused suite: **82 tests / 159 executions**, zero failures/skips/runtime warnings;
  `build/qa-face-interactive-focused-2.xcresult`.
- Final-source complete serial suite: **3,004 tests / 3,917 executions**, zero failures/skips;
  `build/qa-face-interactive-full.xcresult`, 132.846-second test operation. This includes the
  subsequently added deletion-navigation test. The same four previously recorded QoS warnings
  remain in CaptionSessionTests and MetadataEditorReadServiceTests.
- Repository checks pass: `build/qa-face-interactive-repository.log`.
- No native GUI, production-client or hardware gate is claimed complete.

The initial sandboxed build could not write compiler/package caches; the approved invocation
using standard Xcode caches passed. Reading the result summary also used Xcode's report cache.

## Remaining release work

This closes queued interactive face-data save and explicit deletion admission only. Folder-load
expiration cleanup, corrupt-document relocation, other GUI writers, and stale in-memory face-data
snapshots still require coordination. The broader Phase 5A gate remains open: production MCP
workflow tools, template/provider discovery, durable operation status/cancellation, guarded
IPTC prepare/commit and FFmpeg Whisper integration are unfinished.

Real-client workflows, native accessibility/offline/camera/delivery/cloud evidence, external-editor
round trips, supported hardware/performance and migration/recovery drills, external legal/CI gates,
and final signed/notarized candidate packaging and user acceptance remain release requirements.
See `readiness.md` and `gate-inventory.md` for the wider inventory.

## Commands

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/ActivityHistoryTests' \
  '-only-testing:Aagedal Photo Agent Tests/FaceEmbeddingTests' \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-face-interactive-focused-2.xcresult -quiet
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-face-interactive-full.xcresult -quiet
scripts/ci/validate_repository.sh
git diff --check
```
