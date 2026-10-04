# Version 3.0 final checks — 2026-10-04

**Decision: not ready for release.** Automated regression checks pass after two stale test expectations were corrected. Candidate qualification and release-process gates remain open.

## Identity and changes

Baseline: `b87fa4d04978e5c31a467f6c51c969fc70613c11`, initially clean; 3.0.0 build 739. Host: macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Apple Silicon.

Two test expectations changed: transcription history now checks the current saved-text readiness message, and malformed relationship coverage tests a numeric current WAV hash rather than the removed approval field. The project resource exception excluding the required local AuraFace package was removed after a clean Release build omitted the model. The restored `.github/workflows/ci.yml` retains the original workflow/job identities, clean build and unfiltered serial tests, read-only token, manual dispatch, isolated DerivedData and failure diagnostics; current official checkout/upload actions use v7. CI uses ad-hoc signing without release credentials and does not acquire the ignored model. Changes remain uncommitted. The final full tests and Release build include the target membership repair; the three UI smoke cases ran before that resource-only repair.

## Completed checks

- `scripts/ci/validate_repository.sh`: passed, including generated documentation, release metadata, JSON/plist/project syntax, component provenance/hashes, FFmpeg contract, privacy scans, conflict scan and whitespace.
- `scripts/ci/test_release_test_gate.sh`: passed exact/stale/pull-request/dirty/emergency-control harness.
- Full serial Debug tests: 3,810 cases / 372 suites, zero failures, 131.757 seconds. Xcode summary: 3,808 passed, two skipped. The Swift Testing log reports 3,810 passed; retain both reported counts rather than claiming zero skips.
- Native UI smoke tests: folder launch/open, Caption save before advancing, transcript edits and persistence across relaunch; three passed, zero failures/skips, 43.621 seconds. Disposable test fixtures and the suite's isolated profile were used. This is limited Debug workflow evidence, not full Release acceptance.
- Final isolated unsigned Release build: passed after restoring AuraFace resource membership. Model bundle verification passes with 130,342,208-byte weights matching `c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0`.
- Final repository validation: passed after the target membership repair. Workflow YAML and embedded shell syntax also pass.
- `git diff --check`: passed after all edits.

Initial full tests failed with four issues across two test methods: three outdated “unapproved” assertions and one removed-field rejection assertion. The final full rerun passes. Initial sandboxed Xcode package resolution was blocked by cache permissions; approved normal-cache execution succeeded. Runtime host cache `MDB_MAP_FULL` diagnostics remain in logs and are not performance qualification.

## Open gates

1. Exact-source release CI cannot be verified: `gh auth status` fails. `.github/workflows/ci.yml` was absent from HEAD (deleted in `5fe0881`); it has now been restored locally at the user’s request. YAML syntax and embedded shell syntax pass, but remote execution has not been verified. Commit and obtain a successful push run for the final source; required branch protection remains an owner action. Local tests do not replace this gate. No emergency override was used.
2. The October 2 readiness/handoff records still describe unfinished production automation executors, signed Whisper lifecycle/Settings integration, actual provider/offline/GPU qualification, and complete FFmpeg corresponding-source packaging. The newer transcript changes do not establish completion of these requirements. Reconcile each with current implementation and dated evidence.
3. Broader performance/hardware, metadata editor round trips, real delivery servers, recovery/cloud/downgrade, accessibility and qualified legal/privacy evidence remain open per the authoritative plans. Existing automation covers only observed paths.
4. Freeze a candidate, independently review its requirements/evidence, and complete the candidate-specific manual checklist and user acceptance. Distribution signing/notarization, Sparkle/appcast and publication remain later steps.

## Evidence

All logs/results are ignored local build artifacts:

- `build/final-checks-2026-10-04-repository.log`
- `build/final-checks-2026-10-04-gate-selftest.log`
- `build/final-checks-2026-10-04-tests-retry.log` and `.xcresult` (initial assertion failures)
- `build/final-checks-2026-10-04-tests-fixed.log` and `.xcresult` (final pass)
- `build/final-checks-2026-10-04-ui.log` and `.xcresult`
- `build/final-checks-2026-10-04-release.log` (shared database collision)
- `build/final-checks-2026-10-04-release-retry.log` (shared custom-output package module failure)
- `build/final-checks-2026-10-04-release-clean.log` (isolated Release compilation passed, model-bundle validation failed: missing model)
- `build/final-checks-2026-10-04-release-model-fixed.log` (model membership repair)
- `build/final-checks-2026-10-04-tests-model-fixed.log` and `.xcresult` (final target membership)
- `build/final-checks-2026-10-04-repository-final.log`

No source commit, remote configuration, release publication or production delivery was performed.

Workflow references were checked against the official [checkout](https://github.com/actions/checkout), [upload-artifact](https://github.com/actions/upload-artifact), and [macOS runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) documentation.

## Unsigned verification artifact

Path: `build/final-checks-2026-10-04-release-derived/Build/Products/Release/Aagedal Photo Agent.app`, version 3.0.0 (739).
Executable SHA-256: `6f236059b99c67192ab1375fce495a8484100e6b711a7e7b4484135388155791`.
Model validation: `build/final-checks-2026-10-04-model-bundle.json`.
This artifact is an unsigned local build from the baseline plus the reported working-tree edits. It is not a frozen, notarized distribution candidate or evidence of launch acceptance.

## Manual-test follow-up: transcription controls

The user requested two UI adjustments after the checks above. The batch confirmation now starts directly from **Transcribe N Photos**, with that action supplying native consent; the redundant Allow checkbox is removed. Busy/preparation/reset guards and the model's exact-source/provider admission remain in place. Activity History now puts its title above the filters; a red circled-X cancellation button sits at the trailing edge of the active transcription heading, with an explicit tooltip and accessibility label. Cancellation is disabled while a cancellation request is pending.

Verification: final Debug build passes (`build/activity-transcription-layout-2026-10-04.log`); all 14 focused batch model tests pass (`build/batch-transcription-button-model-2026-10-04.log`, `.xcresult`). Three attempted legacy native batch tests fail before reaching confirmation because they search for the removed `caption.voiceMemo.batch.prepare` control (`build/batch-transcription-button-consent-2026-10-04.log`, `.xcresult`); they do not establish native acceptance of the revised overlay. Their obsolete checkbox interactions were removed, but their launch/Activity paths still need updating. Manual visual confirmation remains unrun by the agent. The earlier complete suite and unsigned Release artifact predate these UI adjustments and are not final-source release evidence.

## Manual-test follow-up: batch language and multilingual models

The batch overlay now offers a provider-specific language picker. Whisper includes automatic detection and the shared language list; Apple Speech lists supported locales and requires installed assets. Language changes reprepare the same captured ordered photos and bind the selected language to the exact provider; Settings defaults are unchanged. Custom Whisper retains its admitted executable/model and sandbox grants while overriding only the batch language.

The managed catalog adds multilingual `large-v3-turbo` (1,624,555,275 bytes, SHA-256 `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`) and `large-v3` (3,095,033,483 bytes, SHA-256 `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`) at the existing immutable whisper.cpp revision. Public Hub LFS metadata and an `hf download --dry-run` confirm availability/sizes; no weights were downloaded. These are additional selectable downloads, not newly qualified actual inference evidence. Existing Norwegian catalog entries are preserved.

Focused tests pass: 70 tests / four suites (`build/batch-language-large-turbo-2026-10-04.log`, `.xcresult`), including a new custom-provider language override/readiness/default-preservation case. Final UI-label compilation is recorded in `build/batch-language-large-turbo-final-2026-10-04.log`. Broader native UI and actual Large/Turbo inference remain unverified.

## Manual-test follow-up: nested folder disclosure

Expanding a cached sidebar folder now prefetches the direct subfolders of its newly visible children instead of returning immediately. Shared-sidebar registration for folders opened in another pane performs the same prefetch. Nested folders gain their disclosure chevrons after background discovery without opening/selecting them; empty folders retain no chevron. Scanning remains off the main actor and bounded to the next visible level.

All three sidebar regression tests pass (`build/sidebar-disclosure-final-2026-10-04.log`, `.xcresult`), including a disposable nested/empty-folder case asserting discovery without changing the current folder or expanding descendants. Initial assertion failures were temporary-directory `/var` versus `/private/var` aliases; the final fixture comparison normalizes both sides. Native visual confirmation remains for manual testing.

## Integration follow-up: recover merged Description Assistant

At the user's request, local `main` was fast-forwarded from `b87fa4d` to `ce59cef`, after fetching `origin/main`. The local Description Assistant from [PR #5](https://github.com/aagedal/Aagedal-Photo-Agent/pull/5) is now present with its bundled llama.cpp runtime, model setup, captured-description/face context, proposal review, and guarded application. It improves existing single-photo descriptions through the wand beside Description; Bokmål, Nynorsk and English are supported. Settings → Description Assistant offers explicit Borealis/Gemma 3 4B Q4_K_M downloads; no weights were downloaded or actual inference run in this integration check.

All prior local manual-test fixes were preserved using the named stash `Preserve manual release fixes before syncing description assistant 2026-10-04`, which remains as a backup. Only `readiness.md` conflicted; both upstream evidence and the local report link were retained. Upstream already contains the stale-test and bundled-model membership corrections, so those no longer appear as local changes. The integrated app identity is 3.0.0 build 740 (Beta 1), inherited from main; the earlier build 739 artifact is historical.

Repository validation and conflict/whitespace checks pass (`build/main-description-integration-repository-2026-10-04.log`). Main's required AuraFace build gate invalidated the restored CI workflow's prior model-free assumption; the workflow now reproduces and verifies the model using the manifest-pinned source and locked conversion environment before building. YAML and embedded shell syntax pass; hosted execution remains unverified.

Initial package resolution was stopped after a slow MLX submodule clone. A complete SourcePackages cache from the existing continuation checkout was copied into `build/main-description-packages`; replacement verification uses the checked-in package lock with updates and automatic resolution disabled. Evidence: `build/main-description-integration-cached-2026-10-04.log` and `.xcresult`.

Final integrated verification passes: 3,834 tests / 380 suites, 123.140 seconds, zero failed assertions. Xcode summary reports 3,832 passed and two skipped. The app/test build passes and includes the current merged main plus all restored local fixes. No commit or push was performed; source remains a working-tree candidate.

## Release decision: prepare Beta 2

The user chose a second public beta rather than a final stable release. Debug and Release now use `AAGEDAL_RELEASE_VERSION=3.0.0-beta.2`, numeric bundle short version `3.0.0`, and build `741`, above published Beta 1 build `740`. The changelog has a distinct unreleased Beta 2 section; Beta 1's historical notes remain intact. README points to the next beta. The existing beta-channel behavior continues through the release-version label.

The published appcast remains unchanged: Beta 2 has no fabricated enclosure, signature, checksum or publication record. Commit-specific CI, final candidate packaging/signing/notarization, remaining manual testing and publication remain outstanding. Earlier build 739/740 artifacts are historical and cannot be reused as Beta 2.


### Beta 2 remote CI launch correction

The first restored CI run on `d9874fdd78e9e623045625dc67e2dbab1749c808`
([run 37233213654](https://github.com/aagedal/Aagedal-Photo-Agent/actions/runs/37233213654))
passed repository validation, pinned model reproduction and the clean build.
Test execution failed before any tests ran: RunningBoard rejected the test-host
launch. Build logs show the ad-hoc app retained restricted iCloud entitlements,
without an Apple provisioning profile. CI now overrides `CODE_SIGN_ENTITLEMENTS=`
for its build and test commands. Release project entitlements remain intact;
CI does not qualify iCloud functionality or distribution signatures.
