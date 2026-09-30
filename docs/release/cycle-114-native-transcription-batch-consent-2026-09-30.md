# Cycle 114 — native transcription batch consent

Baseline: `c902a66`, initially clean. Verification ran on the owned dirty source changes;
the identical committed implementation revision is `413af7f`. Documentation is committed separately. No application source changed after
the final native build and integrated run. State remains **IMPLEMENTING**; no whole 3.0 gate closes.
Two bounded sub-agents owned the controller/tests and Caption UI. An independent read-only
reviewer checked consent, ownership, refresh and fixture boundaries. The parent owned input
preparation, readiness, guarded refresh, native fixtures/tests, integration, builds, documentation
and commits. Chat inventory found no other active chat editing this checkout.

## Implemented behavior

- Caption retains the explicit Browser selection in displayed order before narrowing metadata
  editing to one photo. **Transcribe Selected…** accepts 1–8 targets and shows their names, selected
  provider and language. An unchecked consent toggle and a separate confirmation guard execution.
  Cancelling this preview creates no operation, inference or draft.
- Read-only preparation captures exact photo/WAV revisions and relationships without acquiring
  an execution lease or creating coordination files. Final admission recaptures the complete set
  against the consent snapshot before enqueue; changed inputs require fresh preparation/consent.
  Shared-sidecar targets, unsupported/missing relationships and existing saved transcripts refuse
  preparation. Busy metadata/review/save work and current in-memory drafts block native launch.
- Provider selection and parameters are frozen. Apple readiness checks installed assets for the
  selected locale; Whisper revalidates explicitly admitted executable/model identities without
  starting the runner. Both recheck before admission; generation retains its existing per-item
  validation. No provider fallback, asset download, automatic approval or IPTC write is introduced.
- The shared session provider reservation spans final readiness, retained execution and actual
  cancellation teardown. A cancelled view caller cannot release it. Durable cancellation reports
  the verified saved prefix truthfully; transient status failures retain capacity until the owning
  executor returns a terminal result. Cancellation before enqueue reports no drafts created.
- The native sheet exposes ordered saved/failed/stale/cancelled/uncertain outcomes. Saved drafts
  remain editable and unapproved. An uncertain save stops the suffix and asks for inspection, without
  claiming rollback. Caption refresh checks the current photo, generation, empty review and idle
  state both before and after reading; late completion cannot navigate backwards or replace edits.
- Existing single-photo transcription remains available. Locale changes, language release,
  relationship recovery, transcript editing and approval are blocked during batch preparation or
  execution. The original source/WAV/relationship bytes and unrelated editorial values remain
  protected by the shared backend's reservations, exact carrier checks and create-only persistence.

## Verification and environment

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
All fixtures are generated and disposable. No user photos, host language/model installations,
remote mutations or Release candidate are used.

- Pre-final focused suite: **67 tests / five suites**, zero failures/skips, 2.008 seconds,
  `build/qa-v3-cycle114-focused-v3.{log,xcresult}`. Covers no pre-consent effects, immutable order and
  language, exact input drift, saved/new reviews, unavailable/revoked readiness, frozen concrete
  Whisper parameters without Apple fallback, reservation refusal, cancellation before admission,
  caller cancellation with delayed teardown, saved prefixes, uncertain saves, transient status
  failure, guarded review refresh and opt-in fixture configuration.
- Pre-final complete suite: **3,631 tests / 361 suites**, zero failures/skips, 175.005 seconds,
  `build/qa-v3-cycle114-full.{log,xcresult}`. Final integrated suite after all native corrections:
  **3,631 tests / 361 suites**, zero failures/skips, 142.809 seconds,
  `build/qa-v3-cycle114-full-final.{log,xcresult}`; result summary:
  `build/qa-v3-cycle114-full-final-summary.json`. Twelve existing Thread Performance Checker
  diagnostics and 340 host `MDB_MAP_FULL` messages leave broader performance/environment gates open.
- Bundled helper probe: **22 tools**, persistent/pipelined input, malformed-input recovery,
  strict argument refusal, clean exit and zero stderr;
  `build/qa-v3-cycle114-helper-final.{log,json}` (rechecked after the final build).
  Helper SHA-256: `37d34977b193c2165b7d45dec8b042120a664be4bc3670c17f16deb72b27f54a`.
  Its executor boundary remains explicitly unavailable.
- Final repository checks pass in `build/qa-v3-cycle114-repository-final.log`. Whitespace checks
  and 434 local links across all seven changed documents pass before the documentation commit.
- Final native build succeeds (`build/qa-v3-cycle114-ui-build-v6.log`). **Three workflows pass**,
  zero failures, 81.829 seconds, `build/qa-v3-cycle114-ui-final.{log,xcresult}`. They verify preview
  cancellation without operation/sidecar writes; explicit consent, ordered unapproved drafts,
  source/editorial preservation, current-review refresh and exact relaunch persistence; cancellation
  with the first draft saved and second item cancelled; and unavailable-provider/changed-WAV refusal
  before enqueue. Native fixtures use real filesystem admission, retained execution and create-only
  writes, with synthetic readiness/recognition only.
  They do not establish actual Apple or Whisper inference, model accuracy, GPU use or device evidence.

The initial sandboxed Xcode invocation refused compiler/package-cache writes. Authorized Xcode
execution resolved the host restriction. The first runnable focused attempt used a cached temporary
path alias in the new registry fixtures, producing `storageUnavailable`; an unbounded test gate then
stalled the run. The parent interrupted that exact owned test run. Fixtures now use `realpath` and
test gates have bounded waits; final-v3 passes. Product no-follow checks remain unchanged. A helper
probe initially used the wrong bundle subdirectory and was rerun at its actual `Contents/MacOS` path.

The first native run exposed SwiftUI propagation of the sheet identifier onto its direct controls.
An explicit accessibility container now preserves separate consent/action identifiers. The second
run passes unavailable-provider and changed-WAV refusal; two assertions still read only selectable
text labels rather than their accessibility values. The assertions now inspect both. The desktop
diagnostic call stalled for 354.5 seconds and eventually opened a normal empty app after the failed
tests had exited; that diagnostic launch was closed without editing app data. Native result evidence
comes from the recorded XCTest interactions, not that diagnostic launch.

Consent/save/reload/relaunch and refusal then pass in `build/qa-v3-cycle114-ui-v3.{log,xcresult}`,
but cancellation still exposes a stale running summary to accessibility while the recorded video
visibly shows the terminal cancelled result. The targeted diagnostic run at
`build/qa-v3-cycle114-ui-cancellation-final.{log,xcresult}` fails with the exact accessible value
"Transcribing the confirmed photos. 1 of 2 editable drafts saved. Existing reviews are kept."
The summary now has an explicit current accessibility value; the native check waits for that
terminal value. Retained video inspection at `build/qa-v3-cycle114-cancel-observed.png` confirms
the saved first draft and cancelled second item, and the passing final native run verifies the correction.

Exact Xcode commands are retained at the start of each log. Unit runs use Debug,
`platform=macOS`, `-disableAutomaticPackageResolution` and serial testing. Native runs use
the UI Smoke Tests scheme with build-for-testing/test-without-building and named workflow
selections. Automated native interaction is integration evidence, separate from final user acceptance.

## Remaining and next actions

1. Add rooted associated-audio admission and authenticated IPC before enabling helper batch
   invocation. Exercise real installed Apple and admitted Whisper providers, cancellation and
   relaunch/device behavior. The broader Phase 5A batch-transcription criterion remains open.
2. Continue shared face-scan and metadata/Develop-template executors and guarded helper commits.
3. Preserve physical crash/archive-loss, iCloud, signed Whisper lifecycle, authentic Sony/metadata/
   server/hardware, accessibility, display/HDR/solar, performance, legal/privacy, protected CI and
   exact signed-candidate gates. Final user acceptance and publication remain separate; llama.cpp
   stays deferred to 3.1.
