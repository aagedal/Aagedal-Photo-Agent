# Whisper setup inspection cancellation — 2026-10-08

Baseline: `bff0d76`, initially clean. This bounded continuation advances managed
model recovery for 3.0; release state remains **IMPLEMENTING**.

## Behavior

A setup retry previously cleared known installed/corrupt presence before its local
inspection completed. Cancelling that inspection could hide Remove Model or
Download Replacement until a later successful refresh. Inspecting large model
weights includes cancellable hashing, so this is a real lifecycle boundary.

Settings now retains the last known local recovery state until inspection returns
an authoritative result. Task cancellation or an explicit `CancellationError`
preserves those controls without reporting an error or granting provider readiness.
A completed missing-file inspection clears presence; unsafe storage clears recovery
and reports the failure. Completed verified inspection still requires separate
artifact admission before execution. Existing generation checks discard stale
results and revoke late admission receipts.

## Verification

Six new parameterized regression cases cover verified/corrupt prior presence under
task cancellation and explicit cancellation errors, continued provider denial,
absence of extra downloads/admissions, subsequent explicit removal, and reconciliation
of missing/unsafe storage after previous corruption. Existing adjacent coverage checks
model selection races, cancelled admission, publication cancellation, corrupt
replacement, filesystem containment and receipt revalidation.

Independent read-only review found no blocking issues. Its suggested completed
absence/unsafe-storage regression was included before verification finished.

Environment: macOS 27.0.1 (`26A434`), arm64, Xcode 27.0 toolchain. Tests use disposable
local fixtures and isolated preferences. The required ignored AuraFace package was
copied from the main checkout; existing pinned SourcePackages were used with package
resolution and updates disabled. No production weights, preferences or package pins
were changed. Evidence is under ignored `build/continuation-refresh-recovery/`.

Focused verification passes **69 tests / three suites**, zero failures/skips
(`focused.xcresult`, `focused.log`; Swift Testing duration 0.484 seconds).
Integrated regression passes **3,880 tests / 385 suites**, zero failures, with two
opt-in Sony fixture tests skipped (`integrated.xcresult`, `integrated.log`; Swift
Testing duration 123.645 seconds). Four priority-inversion runtime warnings remain
in CaptionSessionTests and MetadataEditorReadServiceTests; performance qualification
remains open. Repository validation and whitespace checks pass (`repository.log`, `repository-final.log`).

Both actual native UI checks pass, zero failures/skips, in 84.290 seconds
(`native.xcresult`, `native.log`):

1. `testManagedWhisperRefusesCorruptCachedModelAcrossRelaunch` creates a small
   corrupt Base file in the isolated test model directory, opens Caption →
   Transcription Settings across relaunch, checks Download Replacement/Remove,
   refuses readiness/transcription, explicitly removes the file, and reopens
   Settings to verify absence. Protected image/WAV/relationship/sidecar bytes remain
   unchanged. Expected behavior was observed.
2. `testManagedWhisperUsesSettingsAndWaitsForExplicitModelDownload` opens Settings
   twice with an empty isolated cache, checks zero downloaded models and explicit
   Download availability, refuses transcription, closes Settings and confirms the
   existing reviewed transcript and protected file bytes remain unchanged. No model
   files appear. Expected behavior was observed.

Both use generated disposable voice-memo fixtures and isolated preferences; teardown
terminates the test app. The native command uses the options below with scheme
`Aagedal Photo Agent UI Smoke Tests`, the two named `-only-testing` selectors under
`Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/`, and `native.xcresult`.
These observed UI paths verify adjacent recovery presentation, not the deterministic
cancellation timing itself.

Tested Debug app: `build/continuation-refresh-recovery/Build/Products/Debug/Aagedal Photo Agent.app`,
version **3.0.0**, build **741**. This is a local test build, not the published beta or
final distribution candidate. Source was baseline plus the two modified Swift files:

| Identity | SHA-256 |
| --- | --- |
| ManagedWhisperSetupModel.swift | `09cd76058f074444eea3f1c1ad323171fdb8e1a1667956b500f3edfee8958561` |
| ManagedWhisperSetupModelTests.swift | `67f839aa3cfd52e292e52a4859e80779ceccd3388a8eeab9f393e51ebcb3ef23` |
| Debug app executable | `788d6d2c6fe0c96a9570c2b37984996b76ac5ae3087e6883c5a035e6b2fb1bf7` |

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-refresh-recovery \
  -clonedSourcePackagesDirPath /Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-refresh-recovery/integrated.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

The focused command uses the same options, with `-only-testing` selectors for
ManagedWhisperSetupModelTests, WhisperModelDownloadServiceTests and
FFmpegWhisperArtifactAdmissionServiceTests, and a separate `focused.xcresult`.

## Remaining gates

This continuation does not qualify the deterministic cancellation race through native
UI interaction, real-model inference, GPU/device behavior, signed descriptor/catalog
lifecycle, distribution signing or complete release acceptance. Production MCP
executors, guarded physical IPTC mutation and broader provider, hardware,
accessibility, privacy/legal and exact-candidate gates remain open.
