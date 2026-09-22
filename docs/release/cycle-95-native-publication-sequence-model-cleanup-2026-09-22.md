# Cycle 95 — native XMP publication, sequence previews and model cleanup

Baseline: `c9d8fb6`, initially clean. Three sub-agents implemented independent publication,
template and model-storage slices; the coordinator connected native publication, integrated tests
and reviewed changes. State remains **IMPLEMENTING**. No whole release gate is newly closed.

## Implemented behavior

Settings → Automation now offers **Publish Approved XMP** after exact plan inspection, a verified
XMP dry run and separate C2PA/pending-draft consent. The production rooted transaction refuses
selected editors, stale sources or changed authority, installs the checked XMP and reconciled app
history, verifies both carriers, and records the operation outcome. Original photo bytes remain
unchanged. Leaving the review requests durable cancellation and suppresses stale UI completions;
verification continues once effects may have occurred. Helper clients still cannot publish.

Successful publication now writes a version-4 verified disposition under the recovery journal lock,
after another rooted identity/byte/authority check. A newly reviewed operation can then stage its
recovery. Interrupted or uncertain records remain unresolved and blocking. The latest completed
material is inspectable until replaced by the next staged publication; this is not permanent undo.
Legacy recovery records remain readable. Explicit restore and safe dismissal of unresolved
pre-write staging are still required before final release.

Template previews additionally resolve `{seq}` and `{seq:1}` through `{seq:9}` in Headline,
Description, Extended Description and Instructions. A single preview uses 1; batch values follow
one-based requested photo order, independently of reservation sorting. Results include resolved
values and sequence indexes. Production interpolation parity, width bounds, stale/revoked authority
and filename-injected placeholders are covered. Approved Keywords and context-dependent variables
still need authoritative production integration.

Signed Whisper lifecycle storage adds explicit interrupted-install cleanup bound to an authenticated
ledger generation. It preflights bounded model-scoped candidates, rejects unsafe files and preserves
current, rollback and signed high-water model bytes. Model staging names now identify their owning
model. Fault tests cover interruption after publication but before ledger commit, cleanup and retry.
Production downloads are unchanged: Settings integration, production signed descriptors, missing-ledger
recovery and legacy unscoped staging still remain.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Implementation commits: `6883908` (sequence previews), `81599eb` (signed-model cleanup),
`2c76013` (native publication, disposition and cancellation). Final regression matches `2c76013`;
only documentation changes follow.
All tests use disposable generated photos, model bytes and signing keys. No production recipient,
photo or model server is modified. Checks target the implementation diff over the baseline.

- Initial sandboxed Xcode invocation could not write compiler/package caches. Approved elevated
  execution built and passed **72 focused tests / six suites**, zero failures, 4.113 seconds:
  `build/qa-v3-cycle95-focused-v2.{log,xcresult}`.
- Native XCTest passed **two workflows**, zero failures, 69.057 seconds:
  `build/qa-v3-cycle95-ui.{log,xcresult}`. The first inspected an exact plan, verified its XMP dry run,
  approved/revoked separate consent and refused a replaced source without changing carriers. The
  second clicked Publish Approved XMP, observed verified completion, checked reconciled pending state
  and unchanged source bytes, then relaunched and verified identical saved XMP/history bytes.
  Earlier cycle-94 activation failures did not recur in these two workflows. Broader UI acceptance
  and interrupted native recovery remain open.
- Final native rerun at `2c76013` stalled before the first workflow assertion. CUA inventory reported:
  “The Mac is locked and automatic unlock could not unlock it.” The coordinator interrupted only
  this run's Xcode process rather than leave it indefinitely waiting. This attempt is **blocked,
  not passed**: `build/qa-v3-cycle95-ui-final.{log,xcresult}` (bundle may be incomplete after interruption).
  Unlock the Mac and rerun the two selected native cases to close this exact-commit UI check. Earlier
  native passes preceded the registry-serialization fix; unit coverage verifies that fix but cannot
  substitute for this final UI rerun.
- Initial complete-suite compilation caught an actor-isolation annotation missing from the new
  cancellation test gate; marking the lock-protected gate nonisolated fixes the test-only error.
- The first complete execution ran **3,375 tests / 351 suites**, with one failure in the new
  cancellation test. Focused diagnostics identified same-instance registry inspection competing
  with the executor's cancellation read through independent nonblocking file-lock descriptors.
  Per-instance synchronous transaction serialization fixes that race while preserving nonblocking
  exclusion across independent instances/processes. The new overlapping read/write test and native
  cancellation test pass with **45 tests / three suites**, zero failures, 2.640 seconds:
  `build/qa-v3-cycle95-cancellation-v4.{log,xcresult}`. An earlier test-only build also required moving
  blocking test coordination from an async closure to a dedicated synchronous queue.
- Final complete regression matching `2c76013`: **3,376 tests / 351 suites pass**, zero failures,
  84.348 seconds: `build/qa-v3-cycle95-full-final.{log,xcresult}`.
- Bundled `Contents/MacOS/photo-agent-mcp` probe passes persistent pipes, pipelining, malformed-input
  recovery, provider discovery and honest executor boundaries:
  `build/qa-v3-cycle95-helper-final.log`, `build/qa-v3-cycle95-helper-final.json`. An initial command used an
  incorrect Helpers path and was corrected after inspecting the built bundle.
- Repository validation and whitespace checks pass: `build/qa-v3-cycle95-repository-final.log`.
  Existing test-host `MDB_MAP_FULL` diagnostics recur without a failing final regression.
- Independent reviews found no blocking publication/disposition issue. The suggested native
  dismissal/cancellation bridge test was added. Filename-injected sequence placeholders were already
  refused before substitution; explicit regression cases now preserve that boundary.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, the unit/UI smoke schemes,
`scripts/ci/validate_repository.sh`, `git diff --check` and `scripts/ci/probe_mcp_helper.py`.

## Remaining before final release

1. Implement explicit interrupted publication recovery and safe pre-write disposition; finish the
   production guarded MCP commit boundary and verified embedded-write preservation.
2. Finish approved Keywords, context-dependent variables and shared face-scan, metadata/Develop
   template and transcription executors, including operation cancellation and real-client workflows.
3. Integrate signed Whisper production trust and downloads, missing-ledger/legacy-orphan recovery,
   source distribution/rebuild and offline/GPU/recognition/storage-failure qualification.
4. Complete authentic Sony, cloud/FTP/SFTP, external metadata interoperability, accessibility,
   display/HDR/solar interaction, performance and recovery evidence; obtain qualified privacy/legal
   review and protected release CI.
5. Verify the exact signed/notarized candidate, complete final user acceptance and obtain publication
   authorization. AI-origin detection remains conditional; llama.cpp remains deferred to 3.1.
