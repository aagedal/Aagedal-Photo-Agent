# Cycle 31 — native voice-memo application

**State:** COMPLETE for the narrow native approved-transcript application and metadata read-back
checkpoint. Overall 3.0 readiness remains **IMPLEMENTING** because offline installed-language
recognition, authorized Sony failure/recovery material, broader accessibility, native archive/
reassociation breadth, real-server delivery and wider release gates remain open.

## Source and scope

- The implementation continues cycle 30 from `b7d2900` on `main`. Verification ran from a dirty
  tree containing only the cycle 31 source, test and documentation changes. Independent review was
  not run in this cycle.
- A gated UI-test launch argument supplies a disposable template-store root. The smoke app installs
  one deterministic template using `{voiceMemoTranscript}` in Headline, Description, Extended
  Description and Instructions without touching the user's real template library.
- The native fixture opens a disposable JPEG with initial metadata, schema-2 relationship, exact
  approved transcript and valid PCM WAV. It verifies the exact Replace preview, cancels with Escape
  and proves the JPEG plus sidecar remain unchanged. After relaunch it verifies the exact Append
  preview, activates Confirm with Return and waits for all four values to become durable.
- A final relaunch reads Headline and Description through the ordinary metadata editor and confirms
  the approved transcript remains available. The image changes only after confirmation; the
  relationship and WAV remain byte exact throughout.
- Cancel and Confirm now have stable accessibility identifiers, Confirm receives initial keyboard
  focus, the application menu and metadata editors expose focused smoke identifiers, and the sheet
  marker remains on its visible heading so it does not overwrite descendant identities on macOS 27.
- The fixture exposed a production race: an empty focus-loss debounce could execute after a template
  application and sweep the newly assigned raw template variables into a later editor save. The
  debounce now schedules only while the metadata editor actually owns unpersisted changes.

## Automated and native verification

- The focused launch-configuration, variable caller and Caption transcription suites pass all 42
  tests across 3 suites.
- The dedicated native application test passes independently. It verifies zero-write cancellation,
  exact Append/Replace copy, keyboard operation, all four compatible fields, relaunch read-back and
  exact relationship/WAV preservation.
- The complete UI smoke target passes all 10 tests together with zero failures, including Browser,
  Import, Caption, Batch Rename, Deadline, Known People and recovery workflows. The result is
  `Test-Aagedal Photo Agent UI Smoke Tests-2026.09.13_22-56-15-+0200.xcresult` in Xcode Derived Data
  and is not committed.
- The exact final source tree's complete serial suite passes 2,906 tests across 314 suites with zero
  failures in 128.545 seconds. The result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_22-59-27-+0200.xcresult` in Xcode Derived Data and is
  not committed.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. Existing compiler and runtime diagnostics remain visible; no new warning is attributed
  to this slice.

## Remaining work

1. Run an installed-language transcription fully offline in the built app and verify persisted
   review across relaunch.
2. Repeat missing, unapproved and stale whole-batch refusal plus multi-image application in the
   built app, and complete VoiceOver traversal/announcement evidence for the preview.
3. Repeat malformed, empty, silent, long-cancellation and language-reservation recovery with
   authorized Sony WAV material.
4. Complete native archive/reassociation breadth and disposable real-server image-plus-WAV
   delivery for FTP, FTPS and SFTP.
