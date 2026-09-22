# Cycle 97 — installed identities, recursive previews and model content recovery

Baseline: `b31f03d`, initially clean. Three sub-agents implemented independent publication,
template and model-storage changes; the coordinator reviewed, integrated, tested and committed.
State remains **IMPLEMENTING**. No whole release gate is newly closed.

## Implemented behavior

Reviewed XMP publication now durably records the installed XMP generation before app-history
installation, then records both generations. Rooted installers bind callback snapshots to the
retained installed descriptor and candidate bytes. Final verification requires the same retained
generations, including after same-byte external replacement. Version-6 incomplete journals retain
originals and candidates; verified completion retains the installed identities. Native recovery
inspection reports available identity evidence. These receipts do not authorize restoration.
A crash between rename and receipt persistence still requires unresolved recovery. Safe removal
of originally absent carriers and restartable restoration journaling remain unfinished.

Automation template previews support acyclic recursive scalar `{field:key}` chains through the
21 canonical retained fields. Memoized expansion is bounded to 32 KiB before allocation, reports
all transitive source fields, and matches production append/replace interpolation. Cycles,
wrong-type or missing sources, any source changed by the template and nested contextual variables
remain refused. Approved Keywords and production template application remain separate work.

The signed Whisper state store can restore missing current model bytes using its existing
authenticated ledger. It preserves exact ledger bytes, generation, rollback state and replay floor;
verifies staged bytes; refuses corrupt/unsafe content and never replaces a target that appears
during restoration. An already verified current copy is accepted on retry after interruption. Staging cleanup starts only after ownership is acquired. This remains an internal
API: production signing descriptors and Settings/download integration are still absent. No trust
is inferred from model bytes, and missing-ledger recovery remains unsupported.

Implementation commits: `c345380` (recursive fields), `c498d88` (model recovery), `ce7f9a4`
(installed identities and helper descriptions). `a21bbd2` adds the native refusal tests.
Only release documentation follows.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures are generated disposable photos/model bytes/signing keys; no user photo or production
destination is changed.

- Initial sandboxed Xcode invocation could not write existing compiler caches. Approved elevated
  execution restored build/test access. The first compilation found a misplaced test assertion
  using a later snapshot; admission correctly has no installed receipt, and the assertion was fixed.
- Independent review found and fixed a transient installed-identity capture race and staging
  cleanup ownership. Follow-up publication, model and native-test reviews found no remaining
  blocking issue within these bounded changes; this is not a whole-candidate release audit.
- Focused final-source verification passes **73 tests / six suites**, zero failures, 2.923 seconds:
  `build/qa-v3-cycle97-focused-final.{log,xcresult}`. Covers recursive parity/refusal/allocation,
  installed receipt persistence/progression/version confusion, actual installed generation,
  interrupted publication, same-byte replacement and signed model recovery/failure/retry.
- Complete regression passes **3,401 tests / 352 suites**, zero failures, 83.519 seconds:
  `build/qa-v3-cycle97-full.{log,xcresult}`. Application source matches `ce7f9a4` (committed while
  this run was executing); only native test/document changes remain outside that revision.
  Existing test-host `MDB_MAP_FULL` diagnostics recur without a failing test.
- Repository validation and whitespace checks pass: `build/qa-v3-cycle97-repository-final.log`. Checklist JSON validates with 39 distinct cases
  and existing source links; human outcomes remain unrun.
- Bundled helper persistent-pipe, pipelining, malformed-input recovery, provider discovery and
  honest executor boundary checks pass: `build/qa-v3-cycle97-helper.{log,json}`. Helper SHA-256:
  `05e69beef63f1c2c9987fd1c3d9b729ce142f5378b5c093bdd689ee9d3d4877b`.
- The first native runner timed out enabling automation before any test executed:
  `build/qa-v3-cycle97-ui.{log,xcresult}`. A CUA app-access request then blocked for approximately
  46 minutes before returning an empty Browser window. The QA app was quit normally; no host
  protection was bypassed or shared daemon reset. Current desktop access supersedes that delay.
- Native retry passes **five workflows**, zero failures, 188.518 seconds:
  `build/qa-v3-cycle97-ui-retry.{log,xcresult}`. Tests cover consent/revocation, unchanged-staging
  resolution, photo same-byte replacement after inspection, external XMP creation after inspection,
  and successful publication/relaunch persistence. The two refusal cases preserve exact journal,
  photo and peer XMP bytes through relaunch and disable resolution after reinspection. App source
  matches `ce7f9a4`; native test source matches `a21bbd2`. Fixture cleanup and app termination
  execute in the test teardown. There is no remaining native-runner blocker for these five cases.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, the unit/UI smoke schemes,
`scripts/ci/validate_repository.sh`, `git diff --check` and `scripts/ci/probe_mcp_helper.py`.
Focused selectors: MCPMetadataTemplatePreviewTests, MCPMetadataTemplateBatchPreviewTests,
WhisperModelDistributionStateStoreTests, MCPIPTCPatchXMPRecoveryStoreTests,
MCPIPTCPatchXMPPublicationAdmissionServiceTests and MCPXMPSidecarInstallationTests.

## Remaining before final release

1. Implement explicit partial-publication restoration with safe absent-carrier removal and durable
   restoration progress, then the guarded helper commit boundary and embedded write preservation.
2. Finish authoritative Approved Keywords, remaining contextual variables, production metadata/
   Develop template, face-scan and transcription executors, cancellation and real-client workflows.
3. Configure production signed Whisper descriptors and Settings/download lifecycle, missing-ledger
   and partial-orphan recovery, source distribution/rebuild and offline/GPU/recognition qualification.
4. Complete authentic Sony, external metadata interoperability, real cloud/FTP/SFTP, accessibility,
   display/HDR/solar, performance and recovery evidence. Qualified privacy/legal review and protected
   release CI remain external dependencies.
5. Verify the exact signed/notarized candidate, complete final user acceptance and obtain publication
   authorization. AI-origin detection remains conditional; llama.cpp remains deferred to 3.1.
