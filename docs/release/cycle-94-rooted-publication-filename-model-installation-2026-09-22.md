# Cycle 94 — Rooted publication, filename previews and verified model installation

Baseline: `7e1c19d`, initially clean. Three sub-agents implemented independent slices and
cross-reviewed publication, template and model behavior; the coordinator implemented the rooted
XMP installer and owns integrated builds, native checks and commits. State remains **IMPLEMENTING**.

Implementation commits: `ffdfda5` (XMP transaction), `505e015` (filename previews),
`2a7dd3f` (model lifecycle), `a2d6371` (final publication durability/verification), and
`238edc7` (fractional-expiry correction). Final regression targets `238edc7`.

## Implemented behavior

The internal XMP transaction now stages original and candidate XMP/app-history bytes in recovery v3,
consumes exact publication consent, installs XMP through retained directory descriptors, reconciles
app history through the production codec and verifies the source and both final carriers. Ancestor,
authority, reservation and revision changes refuse; staging is synchronized and read back before
rename. Original photo bytes remain unchanged. A failure after possible publication reports uncertainty
and keeps recovery material. Legacy v1/v2 journals remain readable. Pending orientation drafts and
Capture Date values that this transaction cannot publish refuse before live writes. Opaque private
extensions and existing history are preserved or refused before publication.

This is an internal tested transaction, not a user-accessible publication workflow. Native consent
and helper tools do not invoke it. Journals remain retained even on success and currently block a
subsequent different publication until recovery disposition is implemented. No embedded writer or
recovery restore/discard capability is added.

Single and batch template previews now resolve `{filename}` for Headline (`title`), Description,
Extended Description and Instructions from each retained canonical photo snapshot. Exact template and
photo revisions still bind the all-or-error preview. Results expose original and resolved values;
unsupported variables, second-order placeholders and oversized expansion refuse. The helper uses the
production filename-only substitution with app-target parity tests; the broader app interpolator has
unavailable helper dependencies. Approved Keywords, other variables and production application remain open.

Signed Whisper lifecycle transactions now copy, hash and synchronize staged model bytes, publish
content-addressed files without replacing retained releases, and commit authenticated release state
last. Rollback verifies retained model bytes; installed lookup rehashes bytes and returns a path that
still requires runner admission. Cancellation after staging preserves the current ledger and model,
cleans staging and permits retry. Production descriptors/signing authority, Settings integration,
orphan cleanup and fault qualification remain open; the shipped pinned downloader is unchanged.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug 3.0.0 (739).
App: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Tests use disposable synthetic photos, temporary recovery/model files and ephemeral signing keys.
No production photo, model server, recipient or credential is modified.

- Sandboxed Xcode package/compiler cache writes were refused; elevated Xcode execution was admitted.
- Initial build found an unavailable app-only interpolator in the helper target; filename-only
  substitution plus a production parity test fixes the boundary.
- Independent review found potential loss of pending Capture Date when clearing pending state;
  pre-write refusal and all-editorial-field final verification now cover it.
- Initial focused execution passed the new publication/model/template behavior but failed a rooted
  install URL equality assertion because the fixture and authorized path use different macOS temp
  aliases. The assertion now checks the admitted target path; carrier/source verification is unchanged.
- Focused integrated run: **83 tests / eight suites pass**, zero failures, 1.696 seconds:
  `build/qa-v3-cycle94-focused-v3.{log,xcresult}`.
- Final publication review corrected the final comparison to include Capture Date and synchronized
  the parent of first-use app-history directories. The publication/review rerun passes **34 tests /
  three suites**, zero failures, 2.455 seconds: `build/qa-v3-cycle94-publication-final.{log,xcresult}`.
- Initial full regression ran **3,363 tests / 351 suites** with one pre-existing fractional-expiry
  failure in native review fixture preparation. A Swift/Foundation reproduction confirms that
  formatting a `.9995` second timestamp can round into the next second, beyond the accepted lifetime.
  Deadline generation now floors explicitly; four deterministic cases exercise retention, durable
  restoration and exact expiry without weakening validation.
- The actual bundled helper probe passes persistent-pipe, pipelining, malformed-input recovery,
  provider discovery and honest unavailable-executor checks: `build/qa-v3-cycle94-helper.{log,json}`.
- Repository validation and whitespace checks pass; the final staged check is recorded below.
- The expiry/store/native-review selection passes **32 tests / two suites**, zero failures,
  1.486 seconds: `build/qa-v3-cycle94-expiry.{log,xcresult}`.
- Native XCTest attempted pending-draft, XMP dry-run/consent and managed-model Settings workflows.
  All three failed at application activation (`Running Background`) before workflow assertions:
  `build/qa-v3-cycle94-ui.{log,xcresult}`. The first activation stalled for 877 seconds and later
  attempts for about 107 seconds each. These are failed/unverified native checks, not passing evidence.
- Direct CUA inspection of the exact Debug candidate subsequently read its Browser window, opened
  Settings with Command-comma, selected Transcription, and observed Apple Speech as the current
  provider plus Whisper and Custom FFmpeg Whisper in its menu. No provider or download action was
  selected. Later interaction reported that the app had changed during test-host activity, so no
  further actions were sent. This proves only that these surfaces were accessible at that moment;
  it does not replace the failed fixture workflows or establish publication/recovery acceptance.
- Final complete regression at `238edc7`: **3,364 tests / 351 suites pass**, zero failures,
  81.161 seconds: `build/qa-v3-cycle94-full-final.{log,xcresult}`. Later changes are documentation only.
- Final bundled-helper probe passes: `build/qa-v3-cycle94-helper-final.{log,json}`.
- Final staged repository validation passes: `build/qa-v3-cycle94-repository-final.log`.
  Whitespace checks pass. Existing test-host `MDB_MAP_FULL` diagnostics recur; no new product defect
  is established by those messages. Native activation failures remain an unresolved validation gap.

Commands use `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 3` with the unit or UI smoke scheme.
Evidence is under `build/qa-v3-cycle94-*`. Repository checks use `scripts/ci/validate_repository.sh`.
The actual bundled helper is exercised with `scripts/ci/probe_mcp_helper.py` (persistent pipes,
pipelining, malformed-input recovery and read-only discovery/refusal).

## Remaining before final release

1. Implement durable publication disposition and recovery actions, then connect native consent and
   the production commit workflow. Embedded writes additionally need verified pixel/codestream preservation.
2. Finish shared face-scan, metadata/Develop-template and transcription executors, approved Keywords,
   broader per-photo variables, operation progress/cancellation and real-client workflows.
3. Configure production signed Whisper descriptors and trust, integrate managed Settings/downloads,
   handle interrupted-install orphans, publish/reproduce source artifacts and qualify offline/GPU,
   recognition quality, interruption and storage failures.
4. Complete authentic Sony/cloud/FTP/SFTP and external interoperability evidence, accessibility,
   HDR/display/solar interaction, performance/recovery, qualified privacy/legal review and protected CI.
5. Build and verify the exact signed/notarized candidate, complete final user acceptance and obtain
   publication authorization. Conditional AI-origin detection stays conditional; llama.cpp stays in 3.1.
