# Cycle 80 — custom Whisper setup and preservation preflight

Baseline `27e450a`, initially clean. Two implementation agents and one independent reviewer
worked alongside coordinator-owned integration, builds, native tests and documentation.
Implementation and tests are committed as `6fbafd9`; validation ran on that diff before commit.
State remains IMPLEMENTING. The provider-choice implementation criterion is complete: Apple Speech
remains selectable, choice persists, and unavailable custom setup gives actionable readiness without
fallback or downloads. The broader Phase 5A exit gate remains open.

## Implementation

- Caption now offers explicit Apple Speech / Custom FFmpeg Whisper selection. The choice
  persists, while selected executable/model access and execution consent last only for the
  panel session. Enable Custom Files captures identities without execution. Transcribe uses
  automatic language detection and CPU inference through the existing exact-WAV provider,
  yielding an unapproved editable draft. There is no automatic download or provider fallback.
- Setup cancellation, reselection, clearing and disappearance revoke readiness. In-flight
  provider closures retain security-scoped access through completion/cancellation teardown.
  Failure retains an existing review and provides actionable messages without raw process logs
  or paths. Custom provenance is visible in the shared review panel.
- MCP schema-3 previews bind exact source/XMP/app carrier presence, lengths and hashes,
  parsed source capabilities, the production exact-copy semantic preservation baseline and
  RAW-safe target-policy alternatives. They select no write mode and grant no approval.
  Durable retrieval reconstructs this entire evidence. Older schema-2 plans fail as stale
  after this upgrade; their original five-minute expiration remains unchanged.
- The semantic baseline excludes all writer-controlled descriptive fields, not only edited
  fields. The protocol explicitly requires unedited-field, unrelated-sidecar, pixel/codestream,
  C2PA, staged write/read-back and recovery checks before any future commit. Write support
  and preservation remain unverified. The helper still exposes no mutation endpoint.
- Pure preservation and target-policy definitions are shared with the helper without pulling
  preference access or physical-writing services into its target. Independent comparison
  verified unchanged existing policies, builder, delivery verifier and execution behavior.
  Preservation fingerprints are calculated only for patch previews, not ordinary metadata reads.
- Help, README, privacy, limitations and the unrun acceptance checklist reflect these boundaries.

## Validation

The first integrated focused run passed **62 tests / six suites**, zero failures, in
**1.911 seconds**. It covers preservation policy/physical fixtures, exact plan reconstruction,
custom setup and the model bridge success/failure cases. Later error-copy and opt-in preservation
changes are covered by integrated validation. The first complete run passed **3,161 tests /
333 suites**, zero failures, in **126.056 seconds**. A final run after the last no-existing-review
message correction passed **3,161 tests / 333 suites**, zero failures, in **130.936 seconds**
(`qa-v3-cycle80-full-final.log` / `.xcresult`). Final repository validation and independent
review pass. Trailing blank-line cleanup after compilation changes no executable behavior. Known LMDB map-size and QoS diagnostics remain observations;
no assertion was weakened.

Initial sandboxed Xcode access was denied required cache writes; the approved build then found
missing helper dependencies. The pure shared-code split fixed compilation without adding a
writer to the read-only helper. Repository validation passed after integration.

All Xcode runs use the project `Aagedal Photo Agent.xcodeproj`, Debug, macOS destination,
`-parallel-testing-enabled NO -jobs 2`. Unit runs use scheme `Aagedal Photo Agent Tests`;
native runs use `Aagedal Photo Agent UI Smoke Tests` and the exact method names below. Focused
unit selection was MCPIPTCPatchPreparationTests, MCPIPTCPatchPlanStoreTests,
FFmpegWhisperSetupModelTests, FFmpegWhisperTranscriptionProviderTests,
MetadataPreservationVerificationTests and DescriptiveMetadataWriteBoundaryTests. Host: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a).
The tested app is version 3.0.0 build 739 at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
It was built from the baseline plus the cycle implementation diff before commit.

The actual bundled helper passes persistent-pipe initialization/discovery, read-only tool
contract and clean EOF: 11 tools, zero stderr bytes. SHA-256:
`358da3109d2d9704d5b25308f150b58f7b3728a68e97c9876a071b91f28c448c`.
This is executable protocol evidence, not full supported-client workflow acceptance.

Ignored evidence: `build/qa-v3-cycle80-{build,focused,full,full-final,repository-final}.log`, focused/full
`.xcresult` bundles and `build/qa-v3-cycle80-helper/{probe.py,probe.log,results.json}`.

## Remaining before release

Guarded IPTC approval, physical preservation/write verification and recoverable commits;
production MCP operations/status/cancellation and supported-client workflows; retained custom
bookmarks, curated signed model lifecycle and bundled Whisper artifact/licensing/size packaging;
real-model accuracy, full audio-format support and native inference/offline/failure acceptance;
authentic Sony/RAW/C2PA and external metadata interoperability; real servers, iCloud/multi-Mac,
interruption, accessibility/display/map/report and performance evidence; qualified legal/privacy
review and protected remote CI; exact-candidate package/review and final user acceptance.
Signing/notarization/distribution require separate authorization. General llama.cpp/GGUF remains 3.1.

## Native Caption evidence

Two distinct real-app XCTest workflows pass on disposable generated image/WAV/sidecar fixtures:

- `testWhisperEvidenceSurvivesNativeReviewApprovalAndRelaunch`: edits and approves the retained
  Whisper draft, relaunches and verifies exact provider evidence, relationship and audio retention
  (26.443 seconds). The prior synthetic transcript fixture is not an actual inference result.
- `testCustomWhisperSetupRequiresFilesAndConsentWithoutChangingReview`: launches with custom
  provider in the process-only defaults domain, verifies unavailable setup/no fallback, opens and
  cancels both real file pickers using Escape, then relaunches. Image, WAV, relationship and approved
  transcript sidecar remain byte-identical; setup remains unavailable without files/consent
  (28.437 seconds). No executable/model was selected or executed.

The initial setup test selected macOS's Touch Bar Cancel proxy and failed at the test-driver layer.
The rerun uses standard keyboard cancellation and passes. The other workflow passed in the original
run. Evidence is `build/qa-v3-cycle80-native{,-rerun}.log` and the corresponding `.xcresult` bundles.
Fixtures are removed and the app terminated by test teardown. No real provider preferences were
changed. Full native custom inference, bookmarks, offline and VoiceOver acceptance remain open.
