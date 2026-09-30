# Cycle 113 — shared transcription batch executor

Baseline: `ed1f0fc`, initially clean. Implementation commit: `20d4c37`. Final application/test
bytes were verified before committing those identical bytes. State remains **IMPLEMENTING**; no whole 3.0 gate closes.
Three bounded sub-agents owned operation progress, transcription persistence, and status/history
presentation respectively. The parent owned the shared batch executor, integration, builds,
documentation and commits. Independent reviewers checked the runner, registry and writer.
Chat inventory found no other active chat editing this checkout.

## Implemented and boundaries

- A shared app-side service admits 1–8 explicit ordered photos before inference. It refuses
  duplicate/shared-sidecar targets and unavailable relationships, retains exact source/WAV revisions,
  and invokes the selected Apple or explicitly admitted Whisper provider serially. It never installs
  language/model assets, switches providers, approves text, expands variables or writes IPTC/XMP.
- Both existing single-photo providers now verify the photo as well as the WAV before and after
  inference. Native associated-input checks refuse linked/special photo, relationship and WAV entries.
  These native checks do not grant rooted MCP audio authority or eliminate arbitrary external-writer
  filesystem TOCTOU intervals.
- Create-only transcript persistence retains the shared photo process reservation and serialized
  photo lock. Existing saved drafts/reviews are refused without replacement. Photo, relationship and
  WAV are checked immediately before creation; exact carrier tokens span precommit hashing and the
  fresh carrier capture in the writer. Read-back checks every unapproved draft field with the existing
  whole-second ISO-8601 persistence normalization. Unknown carrier properties remain preserved.
- Private operation archive schema 2 stores only ordered indices, closed states and outcomes. At most
  64 items can be retained per record; this worker accepts eight. Owner, order, clock, cancellation,
  capacity, strict shape and terminal guards prevent regressions. Legacy schema 1 remains readable;
  schema 2 exists only while batch records remain, and older helpers fail closed. No source paths,
  filenames, transcript text or errors are copied into coordination history.
- Recognition polls durable cancellation and drains provider teardown before acknowledging it.
  Confirmed saves remain `draftSaved`; definite refusal/failure can coexist with saved neighbors.
  Cancellation keeps the verified prefix and queued suffix. An uncertain save or invalid read-back
  stops the suffix and retains recovery evidence without claiming rollback or permitting replay.
  Operation `failed` or `cancelled` does not mean all previous drafts were removed.
- MCP operation status and native history expose counts and numbered outcomes with explicit saved,
  editable, unapproved and IPTC-unchanged wording. Last-recorded running state does not prove liveness.
  Native batch launch/consent and helper transcription invocation remain unfinished. This service is
  a shared backend checkpoint, not a completed user-facing batch tool.

## Review and corrections

Review found cancellation could arrive between the item check and durable start. The runner now
rechecks cancellation on refused admission and preserves the known prefix rather than manufacturing
failure or recovery. Review also found precommit hashing could admit an externally changed carrier
as a fresh write baseline while retaining stale typed editorial values. Exact initial carrier tokens
now survive both the hash interval and writer capture; deterministic tests preserve an externally
edited title and unknown extension byte for byte. A final create-only guard also preserves any
transcript inserted by an external writer between carrier creation and patch preparation. Because
carrier effects may already exist, it reports conservative uncertainty rather than pre-write refusal.
No authority or security checks were weakened.

Initial integration exposed unsupported covariant `Self` in default closures, nested test macro
expansion and helper isolation annotations; these compile issues were corrected. The first runnable
focused suite failed only in new secure-registry fixtures using a temporary-path alias. Fixtures now
use `realpath`, matching the established secure-storage tests. Production no-follow path checks remain.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 build 739.
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
No Release candidate, user photos, real provider assets or remote mutations are used.

- Final focused suite: **144 tests / eight suites**, zero failures/skips, 7.075 seconds,
  `build/qa-v3-cycle113-focused-final-v2.{log,xcresult}`. Covers source/WAV and carrier drift,
  create-only review preservation, real-file two-photo draft reload, whole-second dates, approval
  refusal, serial order/capacity, known saved prefixes, active recognition cancellation, incorrect
  read-back uncertainty, legacy/schema/shape/tampering and privacy-safe status/history.
- Final serial integrated suite: **3,614 tests / 360 suites**, zero failures/skips, 168.299 seconds,
  `build/qa-v3-cycle113-full.{log,xcresult}`. Twelve existing Thread Performance Checker diagnostics
  and host `MDB_MAP_FULL` observations remain; the broader performance gate stays open.
- Bundled helper probe: **22 tools**, persistent/pipelined input, malformed-input recovery, strict
  argument refusal, clean exit and zero stderr; `build/qa-v3-cycle113-helper.{log,json}`.
  Helper SHA-256: `37d34977b193c2165b7d45dec8b042120a664be4bc3670c17f16deb72b27f54a`.
- Repository validation passes in `build/qa-v3-cycle113-repository-final.log`.
- Native test build passes in `build/qa-v3-cycle113-ui-build.log`. Final native workflows pass
  **two tests**, zero failures/skips, 76.950 seconds, `build/qa-v3-cycle113-ui.{log,xcresult}`.
  The batch-history workflow checks verified, failed and cancelled records, exact ordered counts and
  outcomes, unapproved/IPTC-unchanged copy, privacy and byte-exact operation/photo preservation on
  refresh and two launches. Existing stopped-owner recovery/relaunch also passes.
  Native interaction uses isolated seeded operation evidence and disposable generated photos;
  it tests status presentation/relaunch, not production inference, provider availability or native
  batch launch. Exact Xcode invocations are retained at the start of all logs.
- The initial sandboxed Xcode command refused compiler/package-cache writes. Authorized Xcode
  execution resolved that host restriction; no product authority or security checks were weakened.
  The first two authorized attempts failed compilation, then focused v3 failed 26 new fixture cases
  with `storageUnavailable`. Corrected fixtures pass final verification. The preceding 144-test
  focused pass predates the final external-review insertion guard; final-v2 and full results cover it.

Final desktop inventory confirms no Photo Agent app or UI runner remains. Documentation whitespace
and local-link checks are recorded in `build/qa-v3-cycle113-documentation.log`. Repository validation
is repeated after final documentation integration. No Release candidate or whole release gate closes.

Unit runs use scheme `Aagedal Photo Agent Tests`, Debug, `platform=macOS`,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`. Native runs use
`build-for-testing` and `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
120/180-second execution allowances and named workflow selections. Native XCTest results are
automated interaction evidence, not final user acceptance.

## Remaining and next actions

1. Wire this shared executor to explicit native batch launch/consent and immutable selected targets;
   add rooted associated-audio admission and authenticated IPC before exposing helper invocation.
   Provider readiness, real Apple/Whisper cancellation and review-cache refresh need native evidence.
2. Continue shared face-scan and metadata/Develop-template executors and guarded helper commits.
3. Preserve the existing physical crash/archive-loss, iCloud authority, signed Whisper lifecycle,
   real Sony/metadata/server/hardware, accessibility, display/HDR/solar, performance, legal/privacy,
   protected-CI and exact signed-candidate gates. Final user acceptance and publication remain
   separate; llama.cpp remains 3.1.
