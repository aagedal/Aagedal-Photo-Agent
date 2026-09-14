# Cycle 32 — voice-memo batch application

**State:** COMPLETE for the native invalid-authority refusal and two-photo approved-transcript
application checkpoint. Overall 3.0 readiness remains **IMPLEMENTING** because offline
installed-language recognition, authorized Sony failure/recovery material, VoiceOver traversal and
announcement evidence, native archive/reassociation breadth, real-server delivery and wider release
gates remain open.

## Source and scope

- The implementation continues cycle 31 from `7c23c6b` on `main`. Verification ran from a dirty
  tree containing only the cycle 32 source, test and documentation changes. Independent review was
  not run in this cycle.
- A dedicated gated UI-test workflow selects two disposable photos and leaves the Browser visible so
  the ordinary metadata-template control drives the real application path.
- Three separate native launches pair one valid authority with, respectively, a missing, unapproved
  or stale transcript record. Each refuses the complete two-photo batch, reports that zero photos
  were written, never presents a mutation preview and preserves both JPEGs, metadata sidecars,
  relationship records and WAVs byte for byte.
- A fourth native launch supplies two distinct exact-WAV-bound approved reviews. The built app shows
  the exact Replace summary for eight field changes across two photos, accepts keyboard confirmation
  and persists each photo's own transcript to Headline, Description, Extended Description and
  Instructions. Both images change while both relationship records and WAVs remain byte exact.
- The metadata panel now exposes its variable-processing result as a stable accessibility value and
  gives the visible status text its own identifier. This makes whole-batch refusal observable even
  when the status lies outside the instantiated portion of the scroll view.

## Automated and native verification

- The focused launch-configuration suite passes all 4 tests in 1 suite.
- The dedicated native batch test passes with 1 test and zero failures in 82.803 seconds. It covers
  all three invalid-authority launches and the approved two-photo application in one isolated run.
  The result is
  `Test-Aagedal Photo Agent UI Smoke Tests-2026.09.14_20-55-00-+0200.xcresult` in Xcode Derived Data
  and is not committed.
- The first focused native attempt found only a harness observability gap: the offscreen status text
  was not reliably present in the accessibility tree. Exposing the same production status on the
  always-visible metadata panel resolved the gap; no application assertion failed in the final run.
- The exact final source tree's complete serial suite passes 2,907 tests across 314 suites with zero
  failures in 169.089 seconds. The result is
  `Test-Aagedal Photo Agent Tests-2026.09.14_20-59-00-+0200.xcresult` in Xcode Derived Data and is
  not committed.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- A complete UI-smoke-target run was attempted but is not claimed as passing: Notification Center
  and an unrelated `AagedalFTPSync` window took desktop focus while an unchanged cycle 31 test was
  opening its template menu, producing a stale accessibility snapshot. The run was stopped after
  that environmental failure. Cycle 31's complete 10-test pass remains the latest whole-target
  result; the new cycle 32 test passes independently.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. Existing compiler and runtime diagnostics remain visible; no new warning is attributed
  to this slice.

## Remaining work

1. Run an installed-language transcription fully offline in the built app and verify persisted
   review across relaunch.
2. Complete VoiceOver traversal and announcement evidence for the multi-image application preview
   and whole-batch refusal result.
3. Repeat malformed, empty, silent, long-cancellation and language-reservation recovery with
   authorized Sony WAV material.
4. Complete native archive/reassociation breadth and disposable real-server image-plus-WAV
   delivery for FTP, FTPS and SFTP.
