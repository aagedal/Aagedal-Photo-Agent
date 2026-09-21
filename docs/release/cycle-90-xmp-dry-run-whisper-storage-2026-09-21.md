# Cycle 90 — XMP candidate verification and Whisper storage

Baseline: `976e39a`, initially clean. Status remains **IMPLEMENTING**. No broad release
gate closes. Implementation commits: `bb9d7f3` (Whisper storage) and `55482e4` (XMP dry run).
Application/test sources were validated together before committing; subsequent changes only
update release evidence. Three sub-agents supplied XMP staging, independent Whisper work and review;
the coordinator integrated native presentation, tests and documentation.

## Implemented behavior

Settings → Automation → Proofreading Plan Review now offers **Verify XMP Dry Run**.
It revalidates an exact plan, holds the photo reservation, stages the production XMP
transaction in a private temporary directory, checks every writable editorial field and
parsed unrelated/Develop properties plus both orientation tags, then revalidates authority,
expiry and every live carrier. Temporary artifacts are removed before returning evidence.
No photo, XMP or app draft is installed. The UI shows the proposed destination, warnings
and optional byte-count/hash details. Starting a dry run revokes existing consent; clearing,
changing plans, expiry and late completion cannot restore obsolete evidence or approval.
Pending draft values outside the proposed patch are included and explicitly disclosed.

Managed Whisper installed lookup hashes relative to a retained cache-directory descriptor,
rechecks directory/ancestor identity after hashing, rejects group/world-writable model
files and honors cancellation. Missing model entries cannot bypass ancestor validation.
The production URLSession transfer now stages via an exclusive descriptor-relative copy,
with a no-follow regular source, exact bounded bytes, private output and cancellation cleanup.
Replacing a cache pathname during download cannot redirect the new bytes into another folder.
Final publication rechecks ancestors after hashing. Prior model bytes survive refused staging.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Tests use generated JPEGs, synthetic metadata and isolated model/cache files. No user photo,
automation preference, remote server or production recipient is part of these checks.

- Initial focused run: 59 tests / four suites, one test assertion failed because its expected
  `/private/var` pathname differed from the plan's canonical `/var` alias. The assertion now
  derives the destination from the prepared plan's canonical path; production code was unchanged.
- Corrected focused run: **59 tests / four suites pass**, zero failures.
  `build/qa-v3-cycle90-focused-v2.{log,xcresult}` covers XMP candidate verification,
  native review presentation, existing pending-draft execution and Whisper lifecycle.
- Complete integrated regression: **3,295 tests / 343 suites pass**, 110.957 seconds, zero failures.
  Evidence: `build/qa-v3-cycle90-full.{log,xcresult}`.
- Native XMP dry-run/consent/stale-source workflow passes in **25.946 seconds**. It checks visible
  verification, revoked consent, no draft/publication action, byte-identical source and no live
  sidecar creation, then confirms source replacement clears the result and refuses another dry run.
- Existing native pending-draft/history/removal/relaunch workflow passes in **43.278 seconds**.
  Both native cases are in `build/qa-v3-cycle90-native.{log,xcresult}`. Native test teardown stops
  its app and removes generated fixtures; no production preferences are modified.
- Repository validation passes: `build/qa-v3-cycle90-repository.log` and final tracked-file check
  `build/qa-v3-cycle90-repository-final.log`.
- Independent review identified writable installed-model admission and path-based transfer
  staging gaps. Both were fixed and reviewed again; no remaining material findings were reported.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'`, Debug,
`-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3`, the unit/native
schemes and named result bundles. Native workflow selector:
`testAutomationPatchXMPDryRunPreservesPhotosAndRevokesConsent`.
Repository checks use `scripts/ci/validate_repository.sh` and `git diff --check`.

## Remaining release work

- Physical IPTC publication requires distinct consent bound to the selected write mode,
  pending-draft promotion and C2PA consequences; rooted recoverable installation of source,
  XMP and app history; durable original-byte/journal recovery; and embedded pixel/codestream
  preservation. The existing pending-write service writes live files in separate phases and
  cannot simply be exposed as a secure MCP commit endpoint.
- This dry run proves parsed property preservation only. Arbitrary XML extensions, source-embedded
  metadata support, C2PA trust and actual recoverable publication are not established.
- Production face scan, metadata/Develop-template and batch transcription executors remain open.
- Whisper signed versioned descriptors, trusted receipts, authenticated updates/rollback,
  corresponding-source publication, network/low-storage and offline/GPU/recognition qualification remain.
- Authentic Sony/cloud/real-server and external interoperability evidence, accessibility, display/HDR,
  performance/hardware, qualified privacy/legal review, protected remote CI, final signed/notarized
  candidate and user acceptance remain release gates. AI-origin detection remains conditional.
