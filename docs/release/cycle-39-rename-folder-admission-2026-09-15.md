# Cycle 39 — Batch Rename folder admission

**State:** IMPLEMENTING for 3.0. Batch Rename now owns the shared exclusive folder reservation
while its immutable plan executes and while the successful mappings are reassociated with face,
analysis and voice-memo records. Production MCP tools and complete GUI/MCP coordination remain open.

## Change and boundary

- The GUI's existing face/analysis writer barrier and named Develop flush still finish before rename.
  The Develop flush can use a photo lease, so the exclusive folder lease begins immediately afterward
  and precedes execution preflight or the first filesystem move. It stays held through rollback and
  quiescence completion, including post-move reassociation.
- A competing folder/photo reservation refuses execution before any move. The quiescence barrier is
  completed as aborted, the original plan is not executed, and the sheet offers a disk-preview
  refresh before retry. A reservation infrastructure failure is also a refusal.
- This closes the Batch Rename execution interval only. Planning, pre-rename writer quiescence,
  other GUI folder operations, and production MCP workflow tools still need shared coordination.

## Verification

- Source baseline: `d5a22e3b7d291a21112b0328e7c6a323617b0513` on `main`; verification uses
  this cycle's dirty source and test changes. Host: arm64 macOS 27.0 (26A428). Development app:
  3.0.0 (738).
- Focused command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
  'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
  -parallel-testing-enabled NO -jobs 1 '-only-testing:Aagedal Photo Agent Tests/BatchRenameSheetStateTests'`.
  All 19 tests pass. The new refusal/retry case checks unchanged original bytes and zero destination
  writes while a peer holds the folder lease; the existing writer-barrier case now checks that the
  lease remains held through post-move completion and releases afterward. Result bundle:
  `Test-Aagedal Photo Agent Tests-2026.09.15_12-52-48-+0200.xcresult` in Xcode Derived Data.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass on the source/test change.
  A sandboxed Xcode attempt failed before product compilation because SwiftPM/Clang caches were
  outside writable roots; the normal Xcode-cache attempt reached and passed the assertions.
- The complete serial Xcode suite passes **2,920 tests in 315 suites**, zero failures, in
  137.896 seconds against the same app source. Result bundle:
  `Test-Aagedal Photo Agent Tests-2026.09.15_12-53-43-+0200.xcresult` in Xcode Derived Data.
  No native rename/MCP client workflow is claimed for this internal admission change.

## Beta and final-release distance

This is one more coordinated GUI boundary, not a completed Phase 5A exit gate. Beta still needs
the shared production MCP facade with revision-bound metadata reads, status/cancellation and guarded
mutations; coordination for remaining GUI operations; the reproducible FFmpeg build with embedded
Whisper and a hardened model lifecycle; and current-source real-client/native fixture checks.

Final release additionally needs the broader investigation, metadata and solar manual gates,
authentic Sony/physical-volume/cloud/server/interoperability evidence, accessibility and performance
checks on supported hardware, qualified privacy/legal review, protected remote CI, independent
candidate review, exact-candidate user acceptance and separately authorized signing/notarization
and distribution. Open criteria differ greatly in size; the evidence does not support a calendar
date yet.
