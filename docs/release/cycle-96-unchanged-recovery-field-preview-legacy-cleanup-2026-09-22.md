# Cycle 96 — unchanged recovery, retained field previews and legacy model cleanup

Baseline: `ffe40f2`, initially clean. Three sub-agents implemented independent recovery,
template and model-storage slices; the coordinator integrated native Settings, reviewed the
changes and ran validation. State remains **IMPLEMENTING**; no whole release gate is closed.

## Implemented behavior

Automation Settings now provides **Inspect Retained Recovery** and **Resolve Unchanged Staging**.
New publication journals retain their source photo path. Older records accept an explicit original
photo path. Resolution requires the exact original photo, XMP and app-history generations, bytes,
folder authority and unselected editor state under the photo reservation and journal lock. A
separate version-5 unchanged disposition retains original/candidate bytes without reporting
successful publication. A new reviewed operation can replace the resolved staging. Changed,
same-byte-replaced or partially published carriers remain blocked; automatic restore remains open.
Closing Settings cancels queued inspection/resolution and suppresses stale UI completions.

Template previews resolve literal scalar `{field:key}` references in Headline, Description,
Extended Description and Instructions using retained effective metadata. The 21 canonical source
keys follow the production interpolator. A source changed by the same template, recursive variables,
missing/wrong-type metadata or excessive expansion refuses the request. Returned evidence names
resolved source fields. Expansion is bounded before allocation. Approved Keywords still depends on
native cached policy/list authority and has no authoritative helper integration; it remains refused.

Signed Whisper storage adds explicit cleanup of a named legacy UUID staging file only when its full
bytes match retained authenticated current/rollback/high-water authority and another verified durable
installed copy exists. Stale or missing ledgers, unsafe files and unknown/partial bytes remain untouched.
This is an internal API with no production Settings/download caller. Missing-ledger recovery cannot
infer the historical replay floor from model bytes and remains open.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
All fixtures use disposable generated photos, model bytes and signing keys; no production destination
or user photo is changed. Implementation commits: `a676297` (field previews and tool descriptions), `30f2330` (legacy model cleanup),
and `40c1e2a` (native unchanged recovery). Only release documentation follows.

- Initial sandboxed Xcode invocation could not write existing compiler/package caches. Approved
  elevated execution restored build access. Initial builds caught a throwing Boolean expression and
  missing inner `try` in new test macros; both were corrected.
- Initial focused execution ran 89 tests / seven suites. Two native model tests failed because their
  fixture recovery path used Foundation's `/var` spelling instead of the real `/private/var` ancestor
  chain; strict no-symlink persistence refused it. Tests now share the same realpath storage helper
  as staging and explicitly check the service adapter before invoking the model.
- Independent reviews found and resolved pre-allocation variable expansion and native dismissal
  cancellation issues. Model cleanup review found no blocking deletion/authority issue and confirmed
  its internal-only scope. Broader race/failure qualification remains open.
- Complete regression before the final description-only MCP update passes **3,392 tests / 352 suites**,
  zero failures, 80.529 seconds: `build/qa-v3-cycle96-full.{log,xcresult}`. This includes the corrected
  native-model fixture tests, stale-carrier matrix and dismissal cancellation.
- Native XCTest passes **three workflows**, zero failures, 108.992 seconds: consent/revocation,
  interrupted unchanged staging inspection/resolution, and publication/relaunch persistence. Recovery
  verifies unchanged photo and absent sidecars, a version-5 receipt, no unresolved staging on reinspection
  and identical receipt bytes after relaunch. The tested native code matches `40c1e2a`; the subsequent MCP change only updates tool-description text.
  This replaces the preceding locked-host native blocker with passing evidence. `build/qa-v3-cycle96-ui.{log,xcresult}`.
- Final complete regression at `40c1e2a94824cb61b8ed9e8fe3cde659e2ad2db7` passes
  **3,392 tests / 352 suites**, zero failures, 79.663 seconds:
  `build/qa-v3-cycle96-full-final.{log,xcresult}`. Existing test-host `MDB_MAP_FULL` diagnostics
  recur without a failing regression. No application or test changes follow this run.
- Repository validation and whitespace checks pass: `build/qa-v3-cycle96-repository-final.log`.
  Checklist JSON validates with 39 distinct cases including A24; human outcomes remain unrun.
- Bundled helper persistent-pipe, pipelining, malformed-input, provider discovery and honest executor
  boundary probe passes: `build/qa-v3-cycle96-helper-final.{log,json}`.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, the unit/UI smoke schemes,
`scripts/ci/validate_repository.sh`, `git diff --check` and `scripts/ci/probe_mcp_helper.py`.

## Remaining before final release

1. Restore interrupted partial XMP publication using durable installed-file identities and safe
   removal of originally absent carriers; finish the guarded helper commit boundary and embedded
   write preservation. Unchanged staging resolution does not satisfy full rollback.
2. Finish authoritative Approved Keywords, recursive/other contextual variables, shared metadata and
   Develop template, face-scan and transcription executors, cancellation and real-client workflows.
3. Integrate production signed Whisper descriptors and Settings/download lifecycle, missing-ledger
   and partial-orphan recovery, source distribution/rebuild and offline/GPU/recognition qualification.
4. Complete authentic Sony, external metadata interoperability, real cloud/FTP/SFTP, accessibility,
   display/HDR/solar interaction, performance and recovery evidence. Qualified privacy/legal review
   and protected release CI remain external dependencies.
5. Build and verify the exact signed/notarized candidate, complete final user acceptance and obtain
   publication authorization. AI-origin detection remains conditional; llama.cpp remains deferred to 3.1.
