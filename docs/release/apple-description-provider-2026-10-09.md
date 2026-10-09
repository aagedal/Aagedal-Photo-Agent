# Apple Foundation Models description provider — 2026-10-09

Baseline: `da11c94`, initially clean. The user requested Apple Foundation Models as
an alternative to downloadable GGUF models for macOS 27 users. This continuation
adds that optional provider; overall release state remains **IMPLEMENTING**.

## Behavior

Settings → Description Assistant offers explicit Local GGUF / MLX model and Apple
Foundation Models choices. The existing local provider stays the default. Apple
selection persists separately from the local-model bookmark; switching back retains
that local choice. Bookmark renewal does not change provider selection. UI-test
launches use the existing isolated preferences suite.

The Apple backend uses only `SystemLanguageModel.default`, with a fresh session per
caption and no tools or Private Cloud Compute provider. macOS 27 is required for
this integration, including response-token accounting. It checks actual eligibility,
Apple Intelligence enablement and model readiness. Settings explains unavailable
states and offers Check Availability. Language support is queried using the selected
Bokmål (`nb`), Nynorsk (`nn`) or English (`en`) locale; generation repeats readiness
and language admission immediately before inference. No automatic fallback or model
download is performed.

Individual and batch workflows capture the chosen backend before starting. Both
return suggestions through the existing immutable request and explicit review/apply
boundary; changed source descriptions or editor loads still refuse application.
The shared service serializes both providers and local installation, retains busy
admission until cancelled inference returns, and discards late output. Apple refusal,
unsupported language and context errors have actionable messages; output at the
768-token limit is rejected instead of presented as a complete suggestion.

## Verification

Focused verification passes **19 tests / five suites**, zero failures/skips, in
0.045 seconds (`focused-reviewed.xcresult`, `focused-reviewed.log`). New cases cover
unavailable/unsupported admission, captured request identity and deterministic named
person appending, Apple cancellation while refusing concurrent local execution,
failed Apple generation without implicit fallback, provider persistence and actual
local bookmark round-trip/renewal. Adjacent suites retain request, face context,
local inference admission and GGUF completion coverage. Repository validation passes
(`repository.log`, final recheck `repository-final.log`).

Independent read-only review found one provider persistence issue: renewing a stale
local bookmark initially activated the local provider. Renewal now preserves the
selected provider and has a regression. The reviewer confirmed that correction and
the named-person coverage; no further concrete findings remain. The regression
exercises the renewal helper and actual bookmark restoration, rather than forcing
Foundation to return a stale bookmark.

An initial build exposed and corrected a missing return statement. A subsequent
focused run was cancelled after Swift trailing-closure binding routed an existing
local mock into the new Apple injection. Those existing tests now label their local
`textGenerator` explicitly; the corrected focused run passes.

Environment: macOS 27.0.1 (`26A434`), arm64, Xcode 27.0. Existing pinned local
SourcePackages and the restored required AuraFace package are used. Evidence is in
ignored `build/continuation-apple-description/`; builds reuse the previous
`build/continuation-refresh-recovery/` DerivedData. No package pins or production
model weights were changed.

The tested local Debug app is
`build/continuation-refresh-recovery/Build/Products/Debug/Aagedal Photo Agent.app`,
version **3.0.0**, build **741**. Its main executable SHA-256 is
`06eaa4417c2c7bf6f6b0f112dfcf5a5ba4c8f8ca4a16c18aed5d542592448af2`.
Testing used baseline `da11c94` plus this continuation's source changes; this is
local development evidence, not a new published beta or signed release candidate.

The read-only system model probe reports **available**, **Bokmål supported**,
**English supported**, and **Nynorsk unsupported** on this Mac
(`apple-availability.swift`, `apple-availability.log`). This is current runtime
evidence, not a guarantee for other devices, regions or OS/model updates.

The disposable CLI harness compiles the production request and Apple backend source
with a stand-in face-context DTO (no face context is supplied). Real on-device
inference succeeds in English and Bokmål; Nynorsk is refused before inference
(`apple-inference-probe.swift`, `apple-inference-probe`, `apple-inference-probe.log`).
The synthetic English input “Two people attends the football match in Oslo on Friday.”
is returned as “Two people attend the football match in Oslo on Friday.” The Bokmål
input is returned unchanged. These narrow examples verify actual execution, not
representative editorial accuracy or timing/offline acceptance.

Native Settings verification passes **one test**, zero failures/skips, in
36.523 seconds (`native-settings.xcresult`, `native-settings.log`). The generated
voice-memo fixture opens Transcription Settings and selects Description Assistant.
The test selects Apple, checks the visible availability and refresh control, verifies
local-model selection controls are hidden, relaunches using the same isolated
preferences, confirms Apple remains selected, and switches back to the local
provider. Image/WAV/relationship/sidecar bytes remain unchanged. Teardown terminates
the test app.

Earlier native attempts (`native.xcresult`, `native-retry.xcresult`) timed out before
UI automation initialized. After duplicate app instances were closed, the runner
started. Initial suggestion-dialog attempts used a fixture without an eligible
current description and then hit caption-editor event-targeting failures; diagnostic
artifacts are under `native-inspection-attachments/`. They are not passing UI evidence
and do not establish a product defect. The final test covers Settings/persistence;
suggestion-dialog interaction and end-to-end native Apple review/apply remain open.
The computer-use fallback could inspect the built app but was unusually slow; it
was not used to claim provider interaction.

The first integrated run (`integrated.xcresult`) was interrupted: the test host exited
with code 0 before `FFmpegWhisperJobRunnerTests.successAndCleanup` completed, and
Xcode restarted the remaining tests. Its one runner-exit failure is not accepted as
a successful integrated run. The complete uninterrupted rerun passes.

Final integrated verification passes **3,886 tests**, **two opt-in Sony skips**,
**zero failures**, across **386 suites** in **122.642 seconds**
(`integrated-final.xcresult`, `integrated-final.log`). Xcode reports 3,888 total cases
and `TEST SUCCEEDED`. Four existing QoS priority-inversion diagnostics in
CaptionSessionTests and MetadataEditorReadServiceTests leave performance
qualification open. Final repository validation and whitespace checks pass.

## API references and remaining gates

Implementation was checked against the installed SDK27 Swift interface and Apple’s
[SystemLanguageModel documentation](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).
[Apple’s language guidance](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
defines runtime locale support. The framework itself also exists on macOS 26;
Photo Agent deliberately gates this integration to the requested macOS 27 and its
response-usage APIs.

Broader model quality, representative Norwegian editorial text, device/region and
OS-tier qualification remain open. Optional Apple generation does not close the
remaining signed Whisper lifecycle, production MCP executors, physical IPTC mutation,
external hardware, accessibility, privacy/legal or final candidate release gates.

## Reproduction

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-refresh-recovery \
  -clonedSourcePackagesDirPath /Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-apple-description/integrated-final.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

Focused selection uses AppleDescriptionProviderTests, DescriptionAssistantServiceTests,
DescriptionAssistantRequestTests, DescriptionAssistantFaceContextTests and
DescriptionAssistantGGUFTemplateTests. Native verification uses the UI Smoke Tests
scheme with `-only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testDescriptionAssistantAppleProviderAvailabilityAndPersistence'`
and a separate result bundle. The CLI probe compiles the two production Swift files
with `apple-inference-probe.swift` and runs the resulting disposable executable.
