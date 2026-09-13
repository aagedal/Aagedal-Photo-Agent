# Cycle 28 — voice-memo transcription failure matrix

**State:** COMPLETE for the injectable recognition lifecycle, privacy-safe failure mapping and
speech-language reservation recovery criterion. Overall 3.0 readiness remains **IMPLEMENTING**
because native/offline and authorized-Sony recognition, relaunch/application, accessibility,
real-server delivery and the wider release gates remain open.

## Source and scope

- The implementation continues cycle 27 from `6392c97` on `main`. Verification ran from a dirty
  tree containing only the cycle 28 source, test and documentation changes. Independent review and
  native UI execution were not run in this cycle.
- Recognition is now split into independently injectable result consumption, audio analysis,
  finalization and cancellation/finish operations. The consumer starts before analysis, empty audio
  never finalizes, successful analysis finalizes through the last sample, and every failure drains
  the consumer and analyzer through one idempotent teardown.
- Malformed audio, empty audio, no recognized speech, analyzer/result/finalization failures and
  language-install failures have explicit privacy-safe outcomes. A failed or cancelled replacement
  still cannot alter the previously reviewed transcript.
- Language readiness now includes the app's reserved locales and device-reported reservation limit.
  When capacity is exhausted, Caption offers an explicit menu to release a reserved speech language
  before retrying the selected download; it never evicts a language automatically.
- The production boundary continues to use Apple on-device `SpeechAnalyzer`, `SpeechTranscriber`,
  `AssetInventory` and local WAV input. Tests inject the lifecycle and never inspect, install or
  release the developer Mac's actual language assets.

## Automated verification

- The exact final source passes 18 focused transcription tests. New coverage exercises reservation
  exhaustion and explicit release, offline/install and incomplete-download failures, noncooperative
  install cancellation, malformed audio, empty analysis, consumer/finalization failures, long-run
  cancellation, single analyzer teardown and service-executor ownership.
- The exact final tree's complete serial suite passes 2,903 tests in 314 suites with zero failures
  in 118.694 seconds.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. The focused result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_17-44-22-+0200.xcresult` and the serial result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_17-46-46-+0200.xcresult` in Xcode Derived Data; neither
  is committed. Existing compiler and runtime diagnostics remain visible; no new warning is
  attributed to this slice.

## Remaining work

1. Run an installed-language transcription fully offline in the built app, then relaunch and verify
   readiness, persisted review/approval and exact application/read-back.
2. Exercise malformed, empty, silent and long authorized WAVs through the native Caption UI,
   including cancellation, navigation and language release/download recovery.
3. Repeat recognition and relationship validation with authorized Sony card material, including
   moved/reassociated and archived companions.
4. Complete keyboard/VoiceOver acceptance and real-server image-plus-WAV delivery evidence.
