# Cycle 91 — Template previews, XMP recovery material and Whisper trust

Baseline: `7238c43`, initially clean. State remains **IMPLEMENTING**. Three sub-agents
implemented separate slices and cross-reviewed them; the coordinator integrated the helper,
project, storage durability correction, tests and documentation. No broad release gate closes.
Implementation commit: `84064c5`. The complete suite tested this exact application/test source
before commit; later changes only record documentation and verification evidence.

## Implemented behavior

The bundled helper exposes `preview_metadata_template` for one explicitly authorized photo.
It requires the exact template UUID/content hash from `list_templates` and all three carrier
revision tokens from `get_photo_metadata`. Literal descriptive scalar fields and Person Shown
use the editor's Append/Replace behavior, including atomic supplier image IDs. The service
retains photo admission through template inventory/routing/authorization revalidation and then
revalidates the photo. Unsupported fields, Keywords, variables, instant processing, malformed
settings and unknown future template properties fail closed. It creates no durable plan,
approval, draft or physical write. Values describe editor behavior, not publication validation.
Photos in the active Templates directory remain refused by the folder/photo reservation boundary.

`MCPIPTCPatchXMPRecoveryStore` is a passive recovery-material foundation. It retains exact optional
original and candidate XMP bytes, operation/plan/path identity, all three carrier revisions and
authorization generation in a versioned checksummed private journal. Exact retries are harmless;
conflicting operations, corruption and unsafe storage are refused without eviction. One unresolved
record is retained, with no automatic removal, live-carrier access, installation or restore API.
Checksums detect corruption rather than same-account tampering. Physical publication must still
bind this material to retained root descriptors, exact consent and coordinated app-history recovery.

Shared operation persistence now flushes parent directory entries during writable admission,
including existing entries that may remain after an interrupted creator. A sync failure prevents
journal publication; read-only inspection never flushes or creates storage. This closes the
first-use ancestor-directory durability gap found during independent review.

`WhisperModelDistributionTrust` verifies bounded, canonical Ed25519-signed versioned descriptors
and produces opaque authenticated descriptor receipts bound to downloadable model identity.
Pure update/rollback transitions preserve a supplied high-water sequence and permit only the
retained prior release as a rollback proposal. These are copyable proposals, not one-use consent
or durable freshness evidence. A future installer must enforce authoritative persistent state,
atomic generation checks, verified bytes and explicit rollback intent. No production signing key,
remote descriptor, persisted release state or installer/UI integration is configured by this slice;
the existing compiled catalog remains the production authority.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Tests use a generated JPEG, synthetic templates, isolated journals and ephemeral signing keys.
No user photos, production preferences, remote servers or recipient destinations are changed.

- The first build was blocked by sandbox access to Xcode/Swift package caches; the authorized
  elevated run compiled successfully.
- Initial focused run: 88 tests / five suites, eight issues. Seven executions used a Foundation
  temporary-path alias refused by the production no-follow boundary. Fixtures now use POSIX
  `realpath`, consistent with existing registry tests. One malformed-template assertion ran
  against service code compiled before its review fix landed; the final rerun rebuilds that file.
- Corrected focused run: **99 tests / six suites pass**, zero failures, 1.722 seconds.
  Evidence: `build/qa-v3-cycle91-focused-v3.{log,xcresult}`. Includes the new preview/recovery/trust
  suites and existing template discovery, helper core and operation registry regressions.
- Complete integrated regression: **3,313 tests / 346 suites pass**, zero failures,
  86.704 seconds. Evidence: `build/qa-v3-cycle91-full.{log,xcresult}`.
- Repository validation passes with new files staged: `build/qa-v3-cycle91-repository-final.log`.
  Whitespace checks also pass. Existing test-host `MDB_MAP_FULL` diagnostics occurred without a
  failing test; they do not establish a newly diagnosed product issue.
- Independent reviews found the missing parent-directory flush and malformed optional shortcut
  acceptance; both were corrected. Whisper comments/tests now explicitly reject a one-use or
  durable anti-replay interpretation of copyable transition proposals.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'`, the unit-test scheme,
Debug, `-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, and named result
bundles in `build/qa-v3-cycle91-*`. Repository checks use `scripts/ci/validate_repository.sh` and
`git diff --check`. The bundled-helper test launches the actual executable on persistent STDIO
pipes and verifies discovery of the new tool and its required arguments/read-only annotation.
Final independent combined-diff/documentation review reported no material remaining findings.
No GUI behavior changes in this cycle; no new interactive accessibility/manual acceptance is claimed.

## Remaining release work

1. Complete guarded physical IPTC publication: separate mode-bound consent and C2PA/pending-draft
   consequences, descriptor-bound recoverable installation, recovery/disposition UI, app-history
   coordination, semantic read-back and embedded pixel/codestream preservation. Passive recovery
   storage and dry-run evidence do not satisfy this gate.
2. Complete production face scan, metadata/Develop-template batches (variables, approved keywords,
   all supported fields), voice transcription, status/cancellation and real-client integration.
3. Wire authenticated Whisper descriptors into durable model install/update/rollback, configure and
   publish the production trust authority/artifacts and corresponding source, and qualify offline,
   GPU, recognition, network interruption and low-storage behavior.
4. Finish authentic Sony/cloud/real-server and external interoperability evidence; workspace
   accessibility, display/HDR, solar interactions, hardware/performance and recovery validation;
   qualified privacy/legal review and protected remote CI.
5. Build and verify the exact signed/notarized release candidate and complete final user acceptance
   before authorized publication. Conditional AI-origin detection remains conditional.
