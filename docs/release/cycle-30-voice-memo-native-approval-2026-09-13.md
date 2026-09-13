# Cycle 30 — native voice-memo approval

**State:** COMPLETE for native reviewed-text editing, relaunch and approval persistence. Overall
3.0 readiness remains **IMPLEMENTING** because offline installed-language recognition, authorized
Sony failure/recovery material, transcript application/read-back, accessibility, real-server
delivery and wider release gates remain open.

## Source and scope

- The implementation continues cycle 29 from `9ec8a41` on `main`. Verification ran from a dirty
  tree containing only the cycle 30 source, test and documentation changes. Independent review was
  not run in this cycle.
- The dedicated native fixture now opens a disposable JPEG, schema-2 relationship, valid PCM WAV
  and approved transcript; edits the complete review; verifies durable approval revocation;
  relaunches; approves the restored text; and confirms the relationship and WAV remain byte exact.
- That path exposed a production defect: Foundation's ISO-8601 JSON strategy stores whole-second
  dates, so verification compared a successfully reloaded record against the original fractional
  `Date` and falsely reported corruption after approval. Verification now compares canonical
  encoded representations, and transcription persistence returns the canonical record actually
  installed and revalidated.
- A focused regression stores fractional generation and approval dates, then proves the returned
  record is the exact durable representation and matches a fresh load.
- The macOS UI harness now reopens the app's single remembered window when the system restores it
  closed. Sheet workspace markers live on visible headings so macOS 27 does not inherit them over
  descendant control identifiers, and workflow queries accept the accessibility roles exposed by
  the current runtime.
- The full smoke run also exposed a Browser focus defect when a search transitioned to zero results.
  The collection view now stays mounted beneath the no-results presentation, preserving the active
  toolbar editor while results disappear and return.

## Automated and native verification

- The focused voice-memo sidecar and Caption transcription suites pass, including the new
  fractional-date canonical read-back regression.
- The dedicated native edit/relaunch/approval test passes through every product assertion. It
  verifies the final reviewed text and approval after durable reload and exact preservation of the
  relationship and WAV bytes.
- The complete UI smoke target passes all 9 tests together in 124.901 seconds, including Browser,
  Import, Caption, Batch Rename, Deadline, Known People and recovery workflows. The result is
  `Test-Aagedal Photo Agent UI Smoke Tests-2026.09.13_20-54-22-+0200.xcresult` in Xcode Derived
  Data and is not committed.
- The exact final tree's complete serial suite passes 2,905 tests with zero failures in 124.283
  seconds. The result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_21-03-16-+0200.xcresult` in Xcode Derived Data and is
  not committed. A preceding default-parallel attempt was interrupted after Xcode stalled while
  waiting for test workers to materialize; it reported no test failure. Disabling parallel testing
  completed normally.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. Existing compiler and runtime diagnostics remain visible; no new warning is attributed
  to this slice.

## Remaining work

1. Run an installed-language transcription fully offline in the built app and verify persisted
   review across relaunch.
2. Apply the approved transcript through each supported metadata destination, exercise Cancel and
   Confirm with keyboard/VoiceOver, and verify normal metadata read-back after relaunch.
3. Repeat malformed, empty, silent, long-cancellation and language-reservation recovery with
   authorized Sony WAV material.
4. Complete native archive/reassociation breadth and disposable real-server image-plus-WAV
   delivery for FTP, FTPS and SFTP.
