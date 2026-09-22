# Cycle 99 — empty XMP restoration, list shorthand and interrupted model install

Baseline: `e7a71fa`, clean. Three independent implementation changes were committed as
`2688047`, `6cbceab` and `8a8a7fd`. State remains **IMPLEMENTING**; no whole release
gate is newly closed.

## Implemented behavior

- Explicitly confirmed interrupted XMP restoration now preserves an originally existing,
  zero-byte sidecar as a zero-byte file. Normal XMP publication still refuses empty
  candidate data. A durable XMP restoration receipt permits restart and completion.
  Originally absent carriers remain absent. Unreceipted mutation still fails closed:
  matching bytes alone cannot distinguish interrupted installation from external replacement.
- Read-only metadata template previews resolve `{persons}` and `{keywords}` from the
  retained exact photo snapshot. They match production comma-space joins, accept empty
  lists, bound UTF-8 expansion, and refuse changed source fields or second-order
  placeholders. Approved Keywords template-field writes and other contextual variables
  remain outside this preview subset.
- The signed Whisper state store can complete an interrupted installation when the
  content-addressed model was published but the authenticated ledger still holds the
  preceding generation. It verifies the signed receipt, expected generation and installed
  bytes before committing the transition. Missing ledgers, absent/corrupt model bytes and
  replay are refused. Production signed catalog and Settings integration remain open.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). Tests use disposable
photos, model bytes and signing keys. No production recipients or user photos are changed.

- XMP recovery focused run: 25 parameterized test runs, zero failures (agent-isolated
  DerivedData). It covers zero-byte versus absent originals, publication refusal and
  receipt resumption.
- Template preview focused run: 18 tests, zero failures. Whisper state focused run:
  29 tests, zero failures.
- Integrated complete unit regression: **3,425 tests / 353 suites**, zero failures,
  102.820 seconds: `build/qa-v3-cycle99-full-retry.{log,xcresult}`.
  The initial sandboxed run stopped before compilation because Xcode could not write
  compiler/SwiftPM caches; approved elevated execution completed the run.
- Repository validation and whitespace checks pass:
  `build/qa-v3-cycle99-repository.log`. The built MCP helper passes persistent pipes,
  pipelining, malformed-input recovery, provider discovery and honest executor
  boundaries: `build/qa-v3-cycle99-helper.{log,json}`. Helper SHA-256:
  `594f2cde141894d078abccf68f97594b9f7b0f7d544eb1c32be3a332228a995c`.

## Remaining before final release

1. Define authenticated recovery for a mutation without a durable installed receipt,
   cover existing and both-carrier restoration natively, then connect the guarded helper
   commit boundary and verified embedded-write preservation.
2. Finish authoritative Approved Keywords, other contextual variables, production
   metadata/Develop templates, face-scan and transcription executors, cancellation and
   real-client workflows.
3. Configure production signed Whisper descriptors and Settings/download lifecycle;
   resolve missing-ledger/partial-orphan recovery with external authenticated authority,
   source distribution/rebuild and offline/GPU/recognition qualification.
4. Complete authentic Sony, external metadata, cloud/FTP/SFTP, accessibility,
   display/HDR/solar, performance and recovery evidence, plus qualified privacy/legal
   review and protected release CI.
5. Verify an exact signed/notarized candidate, complete final user acceptance and obtain
   publication authorization. AI-origin detection remains conditional; llama.cpp remains
   deferred to 3.1.
