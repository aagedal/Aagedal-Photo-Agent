# Cycle 33 — voice-memo accessibility and offline prerequisite

**State:** COMPLETE for accessible transcript-preview structure, focus and privacy-safe typed status
announcements, plus a built-app offline-recognition release harness. Overall 3.0 readiness remains
**IMPLEMENTING** because spoken VoiceOver observation, the installed English speech-language asset,
authorized Sony failure/recovery material, native archive/reassociation breadth, real-server
delivery and wider release gates remain open.

## Source and scope

- The implementation continues cycle 32 from `379b912` on `main`. Verification ran from a dirty
  tree containing only the cycle 33 source, test and documentation changes. Independent review was
  not run in this cycle.
- The transcript-application sheet now moves accessibility focus to its heading, exports a stable
  summary value, and exposes separately identifiable photo and field groups. The existing keyboard
  focus remains on Confirm, preserving Return confirmation and Escape cancellation.
- Opening the preview and reaching cancel, whole-batch refusal, success or terminal failure now posts
  fixed, privacy-safe typed announcements. No filename, transcript text or other editorial value is
  included in those announcements.
- A gated native release drill creates disposable local speech, uses the production Apple on-device
  recognizer rather than an injected test double, checks that a result is produced, persists a
  deterministic reviewed edit and approval, relaunches, and verifies the relationship plus WAV bytes.
  The drill runs only when `APA_RUN_NATIVE_SPEECH=1` is set.

## Automated and native verification

- The focused accessibility and transcription run passes all 36 tests in 2 suites. It covers the
  expanded fixed-copy catalog, direct AppKit accessibility bypass audit, preview structure and typed
  view-model announcement wiring.
- The dedicated single-launch native accessibility test passes 1 test with zero failures in 23.735
  seconds. It observes the exact two-photo/eight-field summary, both photo groups, all eight field
  groups, Confirm and Cancel in the built app, then closes the sheet with Escape. The result is
  `Test-Aagedal Photo Agent UI Smoke Tests-2026.09.14_23-01-39-+0200.xcresult` in Xcode Derived Data
  and is not committed.
- The production-recognizer drill was invoked with its opt-in environment variable. It reached the
  explicit Download Language state and skipped with zero failures because the English Apple
  on-device speech asset is not installed on this Mac. The app did not download or reserve a system
  language implicitly. The result is
  `Test-Aagedal Photo Agent UI Smoke Tests-2026.09.14_23-03-31-+0200.xcresult` in Xcode Derived Data
  and is not committed.
- The exact final source tree's complete serial suite passes 2,907 tests across 314 suites with zero
  failures in 122.233 seconds. The result is
  `Test-Aagedal Photo Agent Tests-2026.09.14_23-05-05-+0200.xcresult` in Xcode Derived Data and is
  not committed.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- A complete UI-smoke-target run is not claimed as passing. In the whole-target attempt an existing
  multi-launch test intermittently failed to deliver Escape to the sheet. Its focused rerun completed
  both cancel and confirm phases, then stalled while reopening the app menu after the next relaunch.
  The dedicated cycle 33 accessibility test passes independently; cycle 31's complete 10-test run
  remains the latest whole-target evidence.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. Existing compiler and runtime diagnostics remain visible; no new warning is attributed
  to this slice.

## Remaining work

1. Install or explicitly download the English Apple on-device speech language, disconnect networking,
   rerun the gated built-app drill and retain the completed relaunch evidence.
2. Observe and record actual VoiceOver traversal and spoken preview, refusal, cancel, success and
   failure announcements. Automated/native accessibility-tree evidence does not substitute for this.
3. Repeat malformed, empty, silent, long-cancellation and language-reservation recovery with
   authorized Sony WAV material.
4. Complete native archive/reassociation breadth and disposable real-server image-plus-WAV
   delivery for FTP, FTPS and SFTP.
