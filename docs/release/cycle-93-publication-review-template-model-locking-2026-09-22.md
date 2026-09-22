# Cycle 93 — Native publication consent, structured previews and model ledger locking

Baseline: `ace5f8b`, initially clean. Three sub-agents implemented bounded slices and cross-reviewed
consent lifecycle, literal template parsing, recovery admission and model transactions. The coordinator
owns native review integration, builds, GUI tests and commits. State remains **IMPLEMENTING**.

Implementation commits: `8416d6e` (native XMP consent/recovery admission), `5d9d767` (structured template
previews), `8c549ba` (cross-process model state), and `802157c` (process-test startup synchronization).
Final regression targets `802157c`; subsequent changes record documentation and verification only.

## Implemented behavior

Native **Verify XMP Dry Run** now prepares a separate publication review. **Approve XMP Candidate**
requires explicit C2PA/preservation acknowledgement and an independent acknowledgement when every
pending draft value would be promoted. Consent binds the exact candidate, plan, mode and revisions.
Clearing, navigating away, expiry, withdrawing acknowledgement, a new dry run or another approval
revokes it. Late asynchronous grants are revoked. Draft approval remains a separate type and action.
The interface explicitly says publication is unavailable and that no metadata has been published.

Internal XMP admission restages through the production writer, verifies full editorial and parsed
preservation semantics, matches exact candidate bytes, and retains a photo reservation. Recovery v2
stores the original XMP and app-history bytes, operation identity, consent identity and revisions;
legacy passive v1 material remains readable. Admission consumes consent once only after durable
recovery read-back and final checks. It exposes neither candidate bytes nor a live write capability.
No installer, app-history reconciliation, recovery resolution or helper commit endpoint is connected.

Literal template previews now support Media Topic, Genre and Image Supplier using the editor's
production parsers and normalization, including Append/Replace and malformed-input behavior.
Single and batch preview share this implementation. Keywords, variables, instant processing and
unsupported fields still refuse because the requisite reference/approved-list authority is absent.

Whisper release-ledger load/update/rollback now hold a nonblocking exclusive lock on the verified
directory descriptor, serializing cooperating processes across read/compare/replace. Contention
returns `storageBusy`; callers reload before retry. Reads and publication recheck file/directory
identity. The signed release floor survives authorized rollback. This remains release authorization,
not verified installed-byte evidence. External ledger deletion/restoration and noncooperating writers
are outside this protection; production model installation does not yet consume this ledger.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures use generated photos, temporary private journals, synthetic structured metadata and ephemeral
signing keys. Native tests create and clean their own `AagedalPhotoAgentUISmoke-*` fixture directories.
No production photo, model server, recipient or user credential is modified.

- Initial sandboxed build was blocked from compiler/package caches; elevated Xcode execution admitted.
- Early builds caught a missing `try` in the new admission service and actor/macro issues in its tests.
- Independent review found and corrected caller-cancellation propagation through the metadata
  transaction task and duplicate-JSON-key literal validation. New regressions cover both boundaries;
  follow-up review accepted the fixes. A cancellation-test helper also retains requests before task installation.
- The first executable focused run passed six suites but failed nine admission cases because their
  operation/recovery fixture paths contained the macOS `/var` alias. Fixture storage now uses POSIX
  `realpath`; production no-follow checks are unchanged.
- Native pending-draft/history/removal/relaunch workflow passes in `build/qa-v3-cycle93-ui.{log,xcresult}`.
  That first run's XMP consent test assumed a checkbox accessibility role and failed to find the toggle.
  The test now selects its actual accessibility identifier. The corrected dry-run/acknowledgement/
  approval/revocation/source-replacement workflow passes in `build/qa-v3-cycle93-ui-v2.{log,xcresult}`.
  Both cases verify original photo bytes and absence of unexpected sidecar writes. This is observed
  native interaction evidence, not a claim of complete VoiceOver, pending-promotion or release acceptance.
- Final focused run: **59 tests / seven suites pass**, zero failures, 2.926 seconds.
  Evidence: `build/qa-v3-cycle93-focused-v4.{log,xcresult}`.
- Initial full regression ran 3,346 tests / 350 suites with one existing process-cancellation fixture
  failure: its fixed one-second wait expired before the child wrote its startup marker, then attempted
  to read the absent file. Evidence: `build/qa-v3-cycle93-full.{log,xcresult}`.
  The test now races complete child startup evidence against actual process completion, keeps the
  existing deadline, and verifies both process exit and private-job cleanup. The focused Whisper-job
  suite passes **13 tests**, zero failures, 2.629 seconds:
  `build/qa-v3-cycle93-whisper-job.{log,xcresult}`.
- Final complete regression at `802157c`: **3,346 tests / 350 suites pass**, zero failures,
  83.384 seconds. Evidence: `build/qa-v3-cycle93-full-v2.{log,xcresult}`.
- Checklist data validation passes: 38 unique cases, with the new native consent case A23 complete
  and its evidence link resolved. Human acceptance results remain unrun.
- Repository validation passes with final files staged: `build/qa-v3-cycle93-repository-final.log`.
  Whitespace checks pass. Existing test-host `MDB_MAP_FULL` diagnostics recur; no new product defect
  has been established from those diagnostics.

Xcode commands use `test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, selecting the `Aagedal Photo Agent Tests`
or `Aagedal Photo Agent UI Smoke Tests` scheme. Focused selectors cover native review, publication
admission/consent/recovery, single/batch template previews and Whisper state. Native selectors are
`CoreWorkflowSmokeTests/testAutomationPatchXMPDryRunPreservesPhotosAndRevokesConsent` and
`CoreWorkflowSmokeTests/testAutomationPatchAppliesOnlyToPendingDraft`. Result bundles and full logs
are retained under `build/qa-v3-cycle93-*`. Repository validation uses `scripts/ci/validate_repository.sh`
and whitespace checks use `git diff --check`.

## Remaining release work

1. Finish rooted recoverable XMP installation, app-history reconciliation, recovery/disposition UI,
   final semantic verification and production commit integration. Embedded writes additionally need
   verified pixel/codestream preservation.
2. Finish shared production face-scan, metadata/Develop-template and transcription executors;
   per-photo variables and approved Keywords; operation progress/cancellation and real-client tests.
3. Couple authenticated Whisper releases to verified-byte installation/update/rollback, production
   signing artifacts and source publication. Qualify offline/GPU/recognition, interruption and storage failures.
4. Complete authentic Sony/cloud/FTP/SFTP and external interoperability evidence, accessibility,
   HDR/display/solar interaction, performance/recovery, qualified privacy/legal review and protected CI.
5. Build and verify the exact signed/notarized candidate, complete final user acceptance and obtain
   publication authorization. Conditional AI-origin detection stays conditional; llama.cpp stays deferred to 3.1.
