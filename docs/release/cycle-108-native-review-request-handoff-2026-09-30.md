# Cycle 108 — durable native review request handoff

Baseline: `7a41692`, initially clean. Implementation commit: `a5b4618`.
State remains **IMPLEMENTING**; no whole 3.0 release gate is newly closed.
Two implementation agents owned the private request store and helper protocol; an independent
reviewer inspected the integrated change. The parent owned native review/execution integration,
UI fixtures and tests, builds, validation, documentation and commits. No other active chat was
editing this checkout and no unrelated work was staged.

## Implemented

- `request_iptc_patch_review` validates a retained plan before persisting a bounded native review
  intent. Canonical request UUIDs provide exact plan/purpose idempotency; conflicting reuse refuses.
  Exact retries retain truthful status after expiry, source disappearance or helper restart.
  `get_native_review_request` returns intent status and the exact operation link;
  `cancel_native_review_request` records cancellation and forwards it to linked operation history.
  These endpoints require fresh enabled authorization and expose neither consent nor a commit.
- The private checksummed archive holds at most 256 records without eviction. It contains UUIDs,
  purpose and coordination timestamps, without paths or metadata. Owner-only no-follow storage,
  shared cross-process locking, strict schema/state validation and a private hidden directory
  preserve existing storage/admission boundaries. The checksum does not authenticate against a
  malicious writer with the same local account.
- Settings has explicit accessible controls to show, refresh, inspect and cancel client requests.
  Inspection rechecks current plan/source authority and clears previous consent. Requested draft
  and XMP actions are distinct; XMP retains its dry run, separate acknowledgements and approval.
  Only the existing explicit native Apply/Publish action can submit execution.
- Admission is durable before operation enqueue; its exact link is durable before a work task
  starts. Failed admission/linking never schedules work. Interrupted unlinked admissions remain
  unknown and cannot be re-admitted or automatically replayed. No startup timestamp or PID is
  used to infer that another owner stopped. Linked cancellation is checked again at every existing
  safe execution boundary, including when helper forwarding fails; possible effects retain
  conservative recovery outcomes, and verified installed-byte completion still wins late races.
- Native draft, XMP and cancellation services share the same operation-directory resolver.
  The recovery-session fixture uses isolated authorization, in-memory plans, request storage and
  operation history. Native test fixtures create both intents using the actual protocol facade.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Final application bytes were tested before committing identical source as `a5b4618`.
All photos, plans, requests and operation inputs are disposable synthetic fixtures. No user photos,
model downloads or remote writes were used. UI teardown removes native fixtures; normal production
launches cannot enable fixture hooks.

- Final focused characterization: **119 tests / 5 suites**, zero failures, 6.259 seconds,
  `build/qa-v3-cycle108-focused-final.{log,xcresult}`. The preceding 118-test run also passed.
  Coverage includes exact retries, missing/expired plans, settings rechecks, private path refusal,
  cross-store contention, archive corruption/capacity, admission/link gaps, cancellation before
  and after effects, requested native draft/XMP approval and cancellation after inspection.
- Actual native UI workflows: **2 tests**, zero failures, 57.270 seconds,
  `build/qa-v3-cycle108-ui-final.{log,xcresult}`; build evidence is
  `build/qa-v3-cycle108-ui-build-final.log`. Selecting a request grants no consent and creates no
  history. Explicit native approval/application saves a verified pending draft and exact operation
  link. Cancelling another request before admission prevents draft creation. Both exact records
  retain their state after relaunch; original JPEG bytes and absent XMP remain unchanged.
- Final serial integrated suite: **3,547 tests / 358 suites**, zero failures, 160.783 seconds,
  `build/qa-v3-cycle108-full-serial-final.{log,xcresult}`. Twelve Thread Performance Checker
  diagnostics and previously observed `MDB_MAP_FULL` diagnostics remain host observations;
  this cycle does not close the performance gate.
- The actual bundled helper passes the persistent-pipe protocol probe, **21-tool** discovery,
  strict argument refusal, malformed-input recovery and zero stderr,
  `build/qa-v3-cycle108-helper-final.{log,json}`. Helper SHA-256:
  `4d69783815878de8733a3e12ef34a34535287c2b36b79a5d87017545fdd07734`.
- Repository validation and whitespace checks pass in
  `build/qa-v3-cycle108-repository-final.log`; documentation checks pass in
  `build/qa-v3-cycle108-repository-docs.log`.
- Independent review caught inconsistent operation-root resolution in injected recovery sessions.
  A shared resolver, explicit isolated recovery fixture and regression resolve it. Final review
  reports no remaining actionable finding in this slice. The first integrated run found one
  failure in the added concrete-service regression: a default async protocol extension shadowed
  a synchronous actor implementation for concrete calls. Explicit matching async signatures
  resolve it; the final focused/integrated runs include that regression.
- The initial sandboxed Xcode attempt could not write compiler/package caches; the authorized run
  succeeded. The first protocol fixtures used a Foundation path alias, which strict no-follow
  storage correctly refused; POSIX canonical fixture paths fix the tests. The first two UI attempts
  queried/clicked a disclosure heading that did not expand its content. Explicit accessible request
  controls resolve that interaction and pass both actual workflows. No permission/entitlement
  changes or weakening of storage admission were made.

Exact Xcode commands are retained at the start of logs. Unit commands use `xcodebuild test`,
scheme `Aagedal Photo Agent Tests`, Debug, `platform=macOS`, `-disableAutomaticPackageResolution`,
shared derived data above and `-parallel-testing-enabled NO`. Native commands use
`build-for-testing` then `test-without-building`, scheme `Aagedal Photo Agent UI Smoke Tests`,
with 120/180-second allowances and these exact method selections:
`testNativeClientRequestRequiresConsentAndPersistsOperationLink` and
`testNativeClientRequestCancellationPreventsDraftMutation`.
The helper command is `python3 -B scripts/ci/probe_mcp_helper.py '<app>/Contents/MacOS/photo-agent-mcp'
--output build/qa-v3-cycle108-helper-final.json`.

## Remaining before final release

1. Authenticated IPC/helper commits and broader production metadata/Develop/face/template/
   transcription executors remain open. This handoff requires explicit Settings review and native
   execution, and does not launch an app or infer approval from request/plan IDs or digests.
2. The request archive has no removal UI or capacity-recovery protocol; its permanent idempotency
   records fail closed at capacity. Qualify physical crash/link-loss and real-volume interruption
   boundaries, iCloud keyword authority, independent-process preference changes, arbitrary export
   destinations and power-loss durability. Noncooperating writers are outside reservation coverage.
3. Complete production signed Whisper descriptors, Settings/Caption repair wiring, authentic Sony/
   external metadata/cloud/FTP/SFTP evidence, accessibility/display/HDR/solar/performance drills,
   protected CI, qualified privacy/legal review and exact signed-candidate gates.
4. Obtain final user acceptance and separate publication authorization. No Release candidate was
   built this cycle; AI-origin detection stays conditional and llama.cpp/GGUF stays deferred to 3.1.
