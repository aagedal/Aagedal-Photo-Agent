# Cycle 109 — native review outcomes and cancellation

Baseline: `d72e8d3`, initially clean. Implementation commit: `ffe04d2`. Final application
bytes were tested before committing identical source. State remains **IMPLEMENTING**; no whole 3.0 gate closes.
One implementation agent owned native request presentation/service/model tests; a separate
agent investigated capacity recovery and independently reviewed the integrated change. The
parent owned helper protocol/status tests, native UI tests, builds, integration and commits.
No other active chat was editing this checkout; no unrelated work was staged.

## Implemented

- Settings displays matching linked operation evidence: queued/running snapshots, verified,
  refused/stale, confirmed cancellation, unresolved recovery and separately resolved recovery.
  A link alone never implies success. Missing, removed, mismatched or unverifiable history
  remains explicitly unconfirmed; failed refresh clears old outcome evidence.
- Request evidence refresh has its own task and generation, independent of review and execution.
  The visible request list refreshes every two seconds and after completed requested work.
  Refresh/cancellation during execution retain the exact review/request identity. Explicit idle
  refresh still clears consent; inspection, approval and Apply/Publish remain separate.
- Linked work retains an explicit Request Cancellation action. Missing history permits durable
  cancellation intent even when forwarding cannot be confirmed. Wrong-kind links refuse forwarding,
  and terminal outcomes survive late cancellation. A cooperative cancellation request is never
  described as confirmed completion or rollback.
- Helper request status includes nullable `operation` and `operationStatus`:
  `available`, `confirmation-unavailable`, or `not-linked`. The projection matches
  `get_operation_status`, omits owner identity/paths/metadata and always reports executor liveness
  as unknown. Recovery receipt evidence remains separate from the original outcome. Late helper
  cancellation reports `already-terminal` instead of claiming another cancellation was requested.
- Both native and helper cancellation recheck exact enabled authorization before mutation and
  forwarding. Authorized intent persists if a subsequent revocation prevents forwarding;
  revocation before intent prevents that mutation. Status output rechecks authority after reads.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Only disposable generated photos and isolated authorization/request/operation stores are used.
Native teardown terminates the test app and removes fixtures/preferences. No user photos,
model downloads, remote writes or Release candidate were used.

- Final focused run: **129 tests / 5 suites**, zero failures, 8.859 seconds,
  `build/qa-v3-cycle109-focused-final.{log,xcresult}`. Includes every terminal outcome,
  exact non-null recovery evidence, absent/mismatched history, cancellation while a real native
  publication waits at a safe boundary, unchanged photo/XMP bytes, and authorization revocation
  before intent/forwarding. It also preserves consent/request identity during active refresh.
- Actual native workflows: the two draft consent/cancellation cases pass in
  `build/qa-v3-cycle109-ui.{log,xcresult}` (26.098/29.476 seconds). The two affected XMP cases
  pass on their final selection, zero failures, 85.972 seconds,
  `build/qa-v3-cycle109-ui-final.{log,xcresult}`; build evidence is
  `build/qa-v3-cycle109-ui-build-final.log`. XMP request selection grants no draft or publication
  consent. Dry run and separate approval leave photo/XMP/history unchanged; only explicit Publish
  writes the checked XMP and nonpending metadata history. The verified request/operation outcome
  and exact JPEG/XMP/history bytes persist after relaunch. Cancelling after dry run revokes the
  selection and prevents any operation archive or metadata write; its exact request persists
  after relaunch. Four native workflows are observed across these selections, not four tests
  in a single passing final selection. The original cancellation assertion failure is described below.
- Final serial integrated suite: **3,557 tests / 358 suites**, zero failures, 160.495 seconds,
  `build/qa-v3-cycle109-full-serial.{log,xcresult}`. Twelve Thread Performance Checker diagnostics
  and previously observed `MDB_MAP_FULL` host diagnostics remain; the performance gate stays open.
- Actual bundled helper protocol probe: **21 tools**, strict argument refusal, persistent/pipelined
  input, malformed-input recovery, zero stderr; `build/qa-v3-cycle109-helper.{log,json}`.
  Helper SHA-256: `61ce87a8cd21ca6941f4ec23165d295bf8e1cae6490248a65b341ec980a1ca90`.
- Repository validation passes in `build/qa-v3-cycle109-repository.log`; final documentation
  validation passes in `build/qa-v3-cycle109-repository-docs.log`.
- Independent review found and resolved durable cancellation fallback and exact authorization
  recheck omissions. Final application-source review reports no remaining actionable finding.
- The first protocol run failed the existing exact output-key privacy expectation because
  `recoveryResolution` was added. Its explicit expected key set and null assertion now cover
  the intended field. The first combined focused run exposed direct test-store reads racing
  the new completion refresh; lifecycle tests now await both execution and evidence completion
  before nonblocking archive reads. Neither lock semantics nor production assertions were weakened.
- The first native cancellation test correctly reached cancellation with unchanged photo and
  absent XMP/history, then attempted to read an operation archive that had never been created.
  Its assertion now explicitly requires no operation archive before and after relaunch.

Exact Xcode invocations are retained at the start of each log. Focused/integrated unit runs use
scheme `Aagedal Photo Agent Tests`, Debug, `platform=macOS`, the shared derived-data path above,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`. Native runs use
`build-for-testing` and `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
120/180-second execution allowances and the named workflow selections in their logs.

## Remaining and next actions

1. Continue authenticated IPC/guarded helper commits and shared production face, metadata/Develop
   template and transcription executors. Current requests still require explicit native review
   and consent; helper status grants no mutation authority.
2. Implement capacity recovery as a versioned protocol, not row deletion. Read-only investigation
   found that deleting arbitrary UUID idempotency records permits a retried UUID to become a new
   request, including helpers that validated a plan before retirement. A candidate solution binds
   request identity to a durable archive epoch, checks the current epoch inside the archive
   transaction, and atomically rotates it during explicit native recovery. Retained active/unknown
   requests keep their original handles. Earlier unknown epochs must refuse new creation; clients
   must not silently replay them under a new epoch. This design is not implemented or release evidence.
3. Retire only cancelled pre-admission requests or exactly confirmed terminal linked operations
   eligible for removal. Missing operation history, plan expiry, admitted/unknown dispositions,
   live work and unresolved recovery cannot prove safe retirement. Preserve operation/recovery
   material and active cancellation handles; qualify migration, stale helpers, validation/rotation
   races and physical interruption before adding this protocol.
4. Complete iCloud keyword authority, independent-process preference/power-loss and broader native
   interruption evidence, signed Whisper integration, real Sony/metadata/server/cloud/hardware,
   accessibility/display/HDR/solar/performance, legal/privacy/protected-CI and exact signed-candidate
   gates. Final user acceptance and publication authorization remain separate. llama.cpp stays 3.1.
