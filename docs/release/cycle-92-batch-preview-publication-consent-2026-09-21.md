# Cycle 92 — Batch template previews, publication consent and durable model trust

Baseline: `2539366`, initially clean. Three sub-agents implemented and cross-reviewed bounded
slices; the coordinator implemented batch preview, integrated the helper/project and owns validation.
State remains **IMPLEMENTING**. No broad release-readiness gate closes.
Implementation commit: `90da34c`. The full suite tested this exact app/helper/test source; subsequent
changes only record this commit identity and verification evidence.

## Implemented behavior

`preview_metadata_template` now matches editor literal Append/Replace semantics for creator and
organisation lists, scene/subject codes, rights URL, digital GUID, Date Created, country code,
Digital Source Type and urgency, alongside the previous descriptive fields and Person Shown.
Production normalization handles ordered creators, controlled codes and invalid input; invalid date
text preserves the existing date exactly as the editor does. Canonical metadata keys identify output
fields, with `templateField` identifying editor aliases. Variables, Keywords, instant processing and
unsupported structured fields remain refused: variable processing needs explicit reference-source,
processing-order and approved-list/transcript authority that this contract does not yet provide.

`preview_metadata_template_batch` accepts 1–8 explicit photos and one exact template UUID/revision.
Every photo requires all three carrier revisions. Retained photo reservations and descriptor-backed
snapshots enclose the exact template inventory check; revalidation failures discard the entire result.
Results preserve requested order. Duplicate photos and same-stem RAW/JPEG siblings are refused because
they share a sidecar/reservation. Accepted aggregate carrier bytes are bounded to 256 MiB, with at most
one additional captured photo transiently retained before that check; structured result bytes are bounded to
256 KiB; the protocol also includes a text fallback within its separate 1 MiB message limit. No plan, consent, pending draft or publication is created.

XMP preflight now emits an immutable candidate binding constructible only by successful verification.
A separate native publication approval store binds XMP-sidecar mode, exact hash/size/path, plan digest,
carrier/authorization revisions, expiry and explicit C2PA/pending-draft promotion acknowledgements.
Validation needs a retained photo reservation and permanently revokes consent on observed drift.
Existing draft receipts cannot enter this store. There is no new UI, one-shot consume API or physical
installer; validation alone grants no write capability.

The Whisper release authorization ledger persists authenticated descriptor/signature evidence,
re-verifies signatures on load, preserves the signed high-water sequence across rollback and rejects
stale generations across cooperating instances in one process. Storage refuses unsafe files, symlink
ancestors and replaced directories; staging is synchronized, atomically renamed and directory-flushed.
Cross-review found and corrected the parent-symlink/replacement-directory gap. This is not installed
model-byte evidence, cross-process CAS or protection against external ledger deletion/restoration.
The compiled catalog and current downloader remain the production authority. A future installer must
couple this ledger to verified bytes, recovery and explicit update/rollback UI.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures are generated JPEGs, synthetic templates, temporary private journals and ephemeral signing
keys. No user photos, production preferences, model servers or recipients are modified.

- Initial sandboxed build could not write Xcode/package caches; elevated test execution was admitted.
- First compilation caught an `Int`/`Int64` response-count integration error; corrected before tests.
- First focused test run executed 87 tests / seven suites with seven fixture issues: one template
  filename did not match its UUID, and six ledger fixtures used a Foundation temporary-path alias
  that the production no-follow boundary correctly refused. The template fixture correction passes. A rerun still refused the six model fixtures: a standalone
  Swift probe established that `standardizedFileURL` itself rewrites `/private/var` to the symlinked
  `/var` path. Production admission now retains the exact validated absolute path; it does not weaken
  no-follow checks. Test fixtures also use POSIX `realpath`.
- Final focused run: **87 tests / seven suites pass**, zero failures, 1.400 seconds.
  Evidence: `build/qa-v3-cycle92-focused-v5.{log,xcresult}`.
- Complete integrated regression: **3,329 tests / 349 suites pass**, zero failures, 78.770 seconds.
  Evidence: `build/qa-v3-cycle92-full.{log,xcresult}`.
- Repository validation passes with new files staged: `build/qa-v3-cycle92-repository-final.log`.
  Whitespace checks pass. The previously observed test-host `MDB_MAP_FULL` diagnostic recurred;
  it did not cause a test failure and is not evidence of a newly diagnosed product issue.
- Independent reviews cover expanded literal semantics, batch authority/refusal, publication binding
  and signed release-state persistence. Final combined review found a structured-result/wire-response
  size wording issue, which was corrected; no material unresolved finding remains. No GUI acceptance is claimed: new consent/ledger code has no
  UI integration. Helper tests launch the actual bundled executable on persistent STDIO pipes and
  verify both preview tool schemas/read-only annotations.

Tests use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests'
-configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, with focused
`-only-testing` selectors and result bundles/logs under `build/qa-v3-cycle92-*`. Repository checks use
`scripts/ci/validate_repository.sh` and `git diff --check`.

## Remaining release work

1. Connect XMP publication consent to native review UI, one-shot consumption, rooted recoverable
   installation, app-history reconciliation, recovery/disposition UI and final semantic verification.
   Embedded publication additionally needs verified pixel/codestream preservation.
2. Complete production face scan, metadata/Develop-template execution, per-photo variables and
   approved Keywords, transcription, operation status/cancellation and real-client integration.
3. Couple authenticated model releases to durable verified-byte installation/update/rollback,
   production signing authority/artifacts and source publication; qualify offline/GPU/recognition,
   interrupted network and low-storage behavior.
4. Complete authentic Sony/cloud/real-server and external interoperability evidence, accessibility,
   display/HDR/solar interactions, performance/recovery, qualified privacy/legal review and protected CI.
5. Verify the exact signed/notarized release candidate, finish final user acceptance, then obtain
   publication authorization. Conditional AI-origin detection remains conditional.
