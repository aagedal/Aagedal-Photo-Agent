# Cycle 29 — voice-memo review edit durability

**State:** COMPLETE for latest-review persistence and the compiled native relaunch fixture. Overall
3.0 readiness remains **IMPLEMENTING** because the native test could not activate while the Mac was
locked, and offline, authorized-Sony, application/read-back, accessibility, real-server delivery
and wider release gates remain open.

## Source and scope

- The implementation continues cycle 28 from `8bc9156` on `main`. Verification ran from a dirty
  tree containing only the cycle 29 source, test and documentation changes. Independent review was
  not run in this cycle.
- An approved transcript review now enters a serialized durability session on its first edit.
  Every subsequent `TextEditor` update replaces the queued draft, so storage converges on the latest
  complete review instead of retaining only the first incremental edit after approval revocation.
- Photo and locale transitions wait for outstanding review persistence. A transcription replacement
  is unavailable while that write is active, preventing it from racing the reviewed text. Failures
  restore the most recent durable draft and remain explicit.
- The persistence path continues to revoke approval before metadata application and uses the existing
  exact-WAV-bound sidecar transaction. It does not modify the voice-memo relationship or WAV.
- A native UI smoke case now creates a disposable JPEG, valid PCM WAV, schema-2 relationship and
  approved transcript. It edits the review through the native text editor, checks durable revocation,
  relaunches, approves the restored text and verifies the relationship and WAV bytes are unchanged.

## Automated verification

- The exact final source passes 19 focused transcription tests. New deterministic coverage suspends
  the first persistence write, queues a later full edit, attempts a transcription replacement and
  proves both the model and durable store converge on the latest unapproved review.
- The exact final tree's complete serial suite passes 2,904 tests in 314 suites with zero failures
  in 117.035 seconds.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- Tests ran with Xcode's macOS destination on macOS 27.0, arm64, against development version 3.0.0
  build 738. The focused result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_18-35-24-+0200.xcresult` and the serial result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_18-36-09-+0200.xcresult` in Xcode Derived Data; neither
  is committed. Existing compiler and runtime diagnostics remain visible; no new warning is
  attributed to this slice.
- The dedicated UI test target compiled and linked. Its execution stopped before the first product
  assertion because XCTest could not activate the application while the Mac was locked, reporting
  the application in `Running Background`. This is an environment blocker, not native pass evidence.

## Remaining work

1. Unlock the Mac and rerun the dedicated native edit/relaunch/approval test, then complete its
   keyboard and VoiceOver pass.
2. Run an installed-language transcription fully offline in the built app and verify persisted
   review, variable application and metadata read-back across relaunch.
3. Repeat malformed, empty, silent, long-cancellation and language reservation recovery with
   authorized Sony WAV material.
4. Complete native/relaunch policy coverage and disposable real-server image-plus-WAV delivery.
