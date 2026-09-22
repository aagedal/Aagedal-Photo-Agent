# Cycle 100 — native restoration, GPS preview and staged Whisper recovery

Baseline: `5462015`, clean. Implementation commits: `395c6f5`, `47baf6c`, and
`b21160f`. State remains **IMPLEMENTING**; no whole release gate is newly closed.

## Implemented and verified

- A native Automation smoke case now exercises restoration when both an existing XMP
  sidecar and pending app history preceded an interrupted XMP publication. The user
  acknowledges promotion of pending values and explicitly confirms restoration. The
  case checks exact original carrier bytes, the distinct restoration disposition,
  unchanged photo bytes, and persistence after relaunch. Existing unit coverage also
  covers originally absent and zero-byte XMP carriers. Unreceipted restoration still
  fails closed.
- Read-only metadata template preview resolves retained `{gps}`, `{latitude}`, and
  `{longitude}` in supported descriptive fields. It follows production six-decimal
  formatting and empty-coordinate behavior, rejects malformed retained values, and
  preserves bounded output and the no-write boundary. Single and batch tool
  descriptions identify the supported variables.
- Signed Whisper state recovery can complete an interrupted install from a complete
  model-scoped staging file when the receipt and authenticated ledger generation
  match. It verifies exact staged bytes and uses no-replace publication before
  committing the state transition. Partial bytes, invalid names, collisions, replay,
  and a lost ledger remain refused.

## Verification

Environment: arm64 macOS 27.0, Xcode 27.0, Debug 3.0.0 (739). The native case uses
disposable photos and isolated recovery storage; model tests use disposable bytes
and signing keys.

- Existing-carrier native restoration: one UI test passed, zero failures,
  `build/qa-v3-cycle100-ui-final.{log,xcresult}`. The initial build exposed an
  optional fixture value; the first native retry exposed the required pending-draft
  acknowledgement. Both were corrected before the passing run.
- Whisper state-store focused suite: 33 tests passed, zero failures,
  `build/qa-v3-whisper-staging.{log,xcresult}`.
- Metadata template preview focused suite: 21 tests passed, zero failures,
  `build/qa-v3-template-gps-focused-final.log`.
- Integrated unit suite: **3,432 tests / 353 suites**, zero failures, 86.564 seconds,
  `build/qa-v3-cycle100-full.{log,xcresult}`. The test host still emits known
  `MDB_MAP_FULL` diagnostics without a failing test.
- Repository validation and whitespace checks passed:
  `build/qa-v3-cycle100-repository.log`. The built MCP helper passed persistent
  pipes, pipelining, malformed-input recovery, provider discovery, and executor
  boundary checks: `build/qa-v3-cycle100-helper.{log,json}`.

## Remaining before final release

1. Define authenticated recovery for metadata mutation before a durable restoration
   receipt, then complete the guarded helper commit and verified embedded-write
   preservation. Broader native interruption/recovery cases remain.
2. Finish authoritative Approved Keywords and other contextual variables, production
   metadata and Develop template application, face-scan and transcription executors,
   cancellation, and real-client workflows.
3. Connect Whisper's signed production catalog and Settings/download lifecycle;
   lost-ledger recovery needs external monotonic authority. Complete source
   distribution/rebuild and offline, GPU, and recognition qualification.
4. Complete authentic Sony, external metadata, cloud and FTP/SFTP, accessibility,
   display/HDR/solar, performance, recovery, protected CI, and qualified privacy/legal
   review evidence.
5. Verify the exact signed and notarized candidate, complete final user acceptance,
   and obtain publication authorization. AI-origin detection remains conditional;
   llama.cpp remains deferred to 3.1.
