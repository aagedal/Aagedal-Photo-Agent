# Cycle 26 — voice-memo transcript application preview

**State:** COMPLETE for compatible-destination enforcement and the pre-mutation preview boundary.
Overall 3.0 readiness remains **IMPLEMENTING** because native/relaunch application, the wider
transcription failure matrix, Deadline WAV policy and broader release gates remain open.

## Source and scope

- The implementation continues cycle 25 checkpoint `7e5cefb` on `main`. Verification ran from a
  dirty tree containing only the cycle 26 source, test and documentation changes.
- `{voiceMemoTranscript}` is accepted only in the supported editorial-prose fields: Description,
  Extended Description, Headline and Instructions. Repeatable lists, dates,
  controlled values, identifiers and URI-shaped destinations are rejected before mutation. The
  template editor disables insertion for an incompatible row and explains an already-stored
  incompatible token instead of silently coercing it.
- A transcript-bearing batch resolves every photo and revalidates every exact-WAV-bound approval
  before publishing one preview. The preview identifies Append, Replace or existing-variable
  processing, lists each affected photo and write destination, and shows exact before/after values
  for every field the frozen request would change. Transcript destinations are marked explicitly.
- No metadata executor runs until the user selects **Confirm and Write**. Cancel discards the
  prepared requests and states that no metadata was written. If one photo has missing, unapproved,
  stale or changed authority, the complete transcript batch is refused with zero writes; successful
  preparations remain recoverable for an explicit retry after the problem is corrected.
- Confirmation uses the frozen requests shown in the preview and revalidates the complete authority
  set again before the existing per-photo write/read-back boundary. A change before that check
  refuses the whole batch without a partial write. A later corrected recovery retry returns to the
  preview; only the explicit confirmation of the currently presented request set can execute it.

## Automated verification

- Focused interpolator and variable-caller validation passes 47 tests. It proves compatible and
  incompatible destinations, exact Replace previews for separate per-photo transcripts, exact
  Append output, cancel-with-zero-writes, whole-batch refusal and approval revalidation before the
  executor, including the preview requirement after a refused batch is corrected and retried.
- The adjacent write/recovery regression passes 84 tests across five suites.
- The final complete serial suite passes 2,889 tests in 314 suites with zero failures in 155.295 seconds.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass.
- Tests ran with Xcode's macOS destination on macOS 27.0 (26A428), arm64, against development
  version 3.0.0 build 738. The complete suite result is
  `Test-Aagedal Photo Agent Tests-2026.09.13_16-31-44-+0200.xcresult` in Xcode Derived Data and is
  not committed.
  Existing compiler warnings and synthetic LMDB map-full diagnostics remain visible; no new warning
  is attributed to this slice.

## Remaining work

1. Exercise approved, missing, stale, Cancel, Append and Replace application in the built app;
   relaunch and verify normal metadata read-back and keyboard/VoiceOver behavior.
2. Define visible Deadline WAV include/exclude/optional policy and persist the chosen disposition
   in the frozen preflight and delivery receipt.
3. Complete malformed/empty/finalization/install-cancellation, offline, long-file cancellation and
   reservation-limit transcription coverage, then run authorized Sony WAV drills.
4. Broaden authentic archive/recovery/reassociation and physical-volume evidence.
