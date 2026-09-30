# Cycle 107 — cooperative keyword writer coordination

Baseline: `81c059d`, initially clean. Implementation commit: `fa7d005`.
State remains **IMPLEMENTING**; no whole 3.0 release gate is newly closed.
One implementation agent covered managed writers and authority plumbing; an independent
reviewer examined the integrated diff. The parent owned native executor lifetimes,
execution tests, native fixtures/UI tests, builds, integration, documentation and commits.
The earlier coordinator chat was inspected and was inactive; no unrelated work was staged.

## Implemented

- Cooperating managed-list operations share a dedicated cross-process reservation
  namespace. Editor flat/structured saves, Quick List append/import/delete, approved
  imports, archive replace/append, backup restore/preimage capture, legacy migration
  and local/cloud tree reconciliation acquire ownership before their mutation baseline.
  Tree reconciliation reserves every known source and destination before its first
  write. Archive imports preserve truthful earlier committed items when a later
  destination is busy. Sorted, deduplicated acquisition releases its exact prefix
  on failure, and all completed/refused/cancelled paths release ownership.
- POSIX canonicalization resolves the nearest existing ancestor and preserves its
  spelling while appending missing components. Missing-file aliases contend before
  first creation; held coverage remains stable after directory/file creation.
  Parent-symlink drift refuses replacement. Foundation standardization is excluded
  from the retained coverage key, and the lock digest uses the same raw POSIX
  spelling in the app and independent native test runner.
- Approved Keywords capture, preparation and retained-plan validation hold settings
  and list authority while inspecting the photo. Native pending-draft execution
  retains it through installed-byte verification. XMP admission transfers ownership
  into its retained Admission through staging, both carrier installations, verification
  and recovery disposition. Nested plan/approval checks reuse the exact live lease;
  final mutation callbacks continue checking captured bytes, identities and settings.
  Keyword reservations coexist with photo reservations in the same directory.
- Keyword settings setters share one stable production preference namespace across
  local/cloud routing. Busy setters leave preferences/history untouched. A failed
  post-mutation synchronization restores the prior effective setting while keeping
  authority pending and attempts to synchronize that rollback. Routing/cache/cloud
  monitoring publication occurs only after a successful preference transition.
  Failed transitions require a successful explicit retry before authority is ready.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug
3.0.0 (739). App path:
`build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
Final implementation bytes were tested before committing identical source as `fa7d005`.
All photos, lists, settings and recovery inputs are disposable synthetic fixtures;
no user photos, model downloads or remote writes were used. Native fixtures are
removed by test teardown, and production launches cannot enable the fixture hooks.

- Expanded focused run: **208 tests / 18 suites**, zero failures, 14.115 seconds,
  `build/qa-v3-cycle107-focused-v4.{log,xcresult}`. Includes managed imports/restores,
  migration/routing, approval/plan review and adjacent publication checks.
- Final affected focused run after POSIX spelling hardening: **80 tests / 5 suites**,
  zero failures, 6.186 seconds, `build/qa-v3-cycle107-focused-v5.{log,xcresult}`.
  Covers list/settings contention, alias identity, path drift, partial acquisition,
  preference rollback, and native draft/XMP lease lifetimes on success and uncertainty.
- Native UI target builds and both actual XCTest methods pass: **2 tests**, zero
  failures, 57.781 seconds, `build/qa-v3-cycle107-ui-v3.{log,xcresult}` and
  `build/qa-v3-cycle107-ui-build-v3.log`. Publication canonicalizes duplicate input
  to `Oslo`, verifies XMP and reconciled app history, preserves the original JPEG/list
  and retains byte-identical carriers across relaunch. A separate XCTest runner
  holds the actual list lock after native approval; publication refuses before
  creating XMP, app history or a recovery journal, with source/list bytes unchanged.
- Serial integrated suite: **3,517 tests / 356 suites**, zero failures, 160.761 seconds,
  `build/qa-v3-cycle107-full-serial.{log,xcresult}`. Twelve Thread Performance Checker
  diagnostics and the previously observed `MDB_MAP_FULL` diagnostics remain host
  observations; this cycle does not close the performance gate.
- The actual bundled STDIO helper passes the 11-request protocol probe, **18-tool**
  discovery, argument refusal, malformed-input recovery and zero stderr,
  `build/qa-v3-cycle107-helper-final-v3.{log,json}`. Helper SHA-256:
  `de5c7685315e7e1ab76b3799db5411466f54bfc50aea85438c223f034a33f912`.
- Repository validation and whitespace checks pass,
  `build/qa-v3-cycle107-repository-final.log`; final documentation checks are recorded
  in `build/qa-v3-cycle107-repository-docs.log`.
- Independent review identified false-after-mutation preference results leaving
  routing/cache inconsistent. Rollback and its failure tests resolve that finding.
  Focused tests exposed missing-leaf alias drift and filesystem-sensitive coverage
  lookup; POSIX resolution and stable lexical keys resolve both. The final reviewer
  reports no remaining actionable finding in this slice.
- The initial sandboxed Xcode attempt could not write compiler/package caches; the
  authorized Xcode run succeeded. The first native contention attempts used O_RDWR,
  which XCTest's sandbox refused with EPERM. The final runner uses its permitted
  O_RDONLY descriptor to flock the existing file without modifying its bytes. No
  entitlement or permission change was made. Native logs retain the previously
  observed display-rectangle/debugger diagnostics without a failing final test.

Exact Xcode commands are retained at the start of the logs. Unit commands use
`xcodebuild test`, scheme `Aagedal Photo Agent Tests`, Debug, `platform=macOS`,
`-disableAutomaticPackageResolution` and `-parallel-testing-enabled NO`.
Native commands use `build-for-testing` followed by `test-without-building`, scheme
`Aagedal Photo Agent UI Smoke Tests`, with these two exact method selections:
`testAutomationKeywordPublicationPersistsAcrossRelaunch` and
`testAutomationKeywordPublicationRefusesIndependentWriter`.
Both use 120/180-second execution allowances and the shared derived-data path above.
The helper command is `python3 -B scripts/ci/probe_mcp_helper.py '<app>/Contents/MacOS/photo-agent-mcp' --output build/qa-v3-cycle107-helper-final-v3.json`.

## Remaining before final release

1. Implement a durable intent-only helper request handoff to explicit native review
   and the existing consent/executor. Serialize request admission and cancellation,
   record admission before enqueueing, and retain an unknown disposition if a crash
   loses the operation link; never replay or infer consent from a plan ID/digest.
   Authenticated IPC/helper commits and broader production executors remain open.
2. Extend/qualify keyword authority for iCloud and independent-process preferences.
   Arbitrary user-selected export destinations, raw preference/file writers and
   external cloud updates do not participate in these managed-operation reservations.
   Real-volume interruption and physical power-loss durability remain open.
3. Complete production metadata, Develop, face-scan, template and transcription
   executors, production signed Whisper descriptors and Settings/Caption repair wiring.
4. Close authentic Sony/external metadata/cloud/FTP/SFTP, accessibility, display/HDR/
   solar, performance, protected CI, qualified privacy/legal and exact signed-candidate
   evidence gates; obtain final user acceptance and separate publication authorization.

No new Release candidate was built. Cooperative reservations do not constrain
noncooperating writers or malicious modification by the same account. AI-origin
detection stays conditional, and llama.cpp/GGUF stays deferred to 3.1.
