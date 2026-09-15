# Cycle 36 — cross-process operation reservations

**State:** IMPLEMENTING — the reservation primitive and three retained GUI metadata-write entry
points are implemented and pass an app build plus second-process smoke check; Xcode test assertions
remain unverified. Overall 3.0 readiness remains **IMPLEMENTING**. The production MCP facade and tools, coverage
of other GUI operations and directory-wide workflows, FFmpeg Whisper, and wider release gates remain
open.

## Change

- The app and bundled MCP helper compile the same keyed, advisory filesystem reservation code. A
  photo lease holds a shared folder reservation and an exclusive extension-independent photo
  reservation; a folder lease is exclusive. A busy lease fails before work starts. Lock files use
  SHA-256 names in a same-user, mode-0700 temporary directory and reject symlinks, unexpected file
  type/owner/link count, and insecure permissions.
- Retained field mutations, Write All, and Primary Develop saves hold a photo lease across their
  prepare, physical write, sidecar/XMP completion and read-back boundaries. Their existing captured
  intent, revision checks, rollback and recovery evidence remain authoritative. A busy field mutation
  is reported as a prepare-stage conflict before changing any carrier.
- The per-photo `MetadataIOCoordinator` still orders I/O within the GUI process. The reservation
  primitive provides a cross-process admission boundary for future MCP operations and these three
  GUI flows; it does not yet cover every GUI writer, rename/face scan, folder move/archive, or a
  production MCP workflow.

## Verification

- The `Aagedal Photo Agent` scheme builds successfully with one Xcode build job, including its MCP
  helper dependency.
- A standalone Swift 6 smoke executable compiled the exact shared MCP core and exercised sibling
  RAW/JPEG refusal, folder/photo overlap, release/reacquisition, and refusal while a second process
  held the lease. All checks passed.
- Two focused Swift Testing cases were added for primitive conflicts and GUI field-write zero-write
  refusal. Both affected test sources typecheck directly against the newly built app module with
  Xcode's Swift 6 actor-isolation and macro-plugin settings. Three Xcode test-target attempts did not
  reach assertions: the Xcode 26.6 Swift compiler
  driver intermittently reported `SwiftCompile ... exit code 0 but produced no further output` on
  unrelated test files, then stalled. The test cases and complete suite remain unverified in this
  cycle. The exact app build and smoke check are narrower evidence.

## Remaining work

1. Connect all GUI metadata/Develop, face/rename and folder mutations to shared admission, while
   preserving the in-process coordinator's ordered writes and avoiding nested cross-process locks.
2. Build the production automation facade, explicit operation status/cancellation and revision-bound
   metadata discovery, then guarded mutation tools.
3. Rerun the focused and complete Xcode suites when the compiler driver reliably completes, and
   exercise GUI/MCP contention from a real MCP client with exact fixture read-back.

## Beta and final-release assessment

This is a working assessment, not a dated release commitment. The current authoritative plans have
85 unchecked criteria: 9 improvement-audit, 23 investigation-delivery, 47 journalistic-metadata and
6 solar. Phase 5A alone has 26 unchecked criteria. Checklist counts measure scope, not equal-sized
work or calendar time.

A 3.0 beta is still several feature milestones away. The mandatory production MCP workflows and
FFmpeg Whisper provider do not exist yet, and the coordination boundary covers only three GUI write
flows. A useful beta cut needs those workflows, exact read/write and cancellation evidence from a
real client, current-source automated regression, and a disposable native offline/Sony drill. The
compiler-driver interruption also leaves this cycle's new Xcode assertions pending.

Final release is further away: authentic Sony and real-server transport, broader physical-volume and
accessibility/hardware/interoperability checks, signed/offline model lifecycle, qualified privacy/legal
review, protected remote CI, independent readiness review, exact-candidate user acceptance and
signing/notarization/distribution remain open. There is no defensible final-release date from the
current evidence.
