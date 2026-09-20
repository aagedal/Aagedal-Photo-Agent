# Cycle 84 — operation tools, Whisper options and consent expiry

Baseline `a258aa2`, initially clean. Three agents implemented disjoint operation, Whisper and
approval-lifecycle slices; implementation is committed as `d0376b8`. The coordinator integrated helper target membership, native smoke
coverage, live protocol probes and documentation. Independent reviews covered operation tools
and Whisper settings. Readiness remains IMPLEMENTING; no broad release gate is closed.

## Implemented behavior

- `get_operation_status` and `cancel_operation` use the shared durable registry. Both require fresh
  local automation authority and exactly one UUID operation ID. Results distinguish state,
  terminal outcome and cancellation request, without exposing owner IDs, paths or editorial data.
  Repeated cancellation survives helper restart without claiming the owner stopped. Capabilities
  explicitly report that production executors are not connected and liveness is unknown.
- Custom Whisper saves language (`auto` or a two-letter code), translation into English and GPU
  request settings. Each provider snapshots its settings; draft evidence records the exact request,
  independently of later UI edits. Invalid language prevents transcription. Consent and artifact
  checks remain session-bound. Schema 1 retains its untranslated contract; translated evidence uses
  schema 2 so older readers refuse it rather than misinterpret it. The attributed filter source
  supports these options; actual custom model/GPU compatibility still requires runtime acceptance.
- Proofreading expiry now revokes consent and cancels outstanding approval work. Delayed receipts
  after Clear, plan-ID changes or expiry are revoked. A receipt expiring between service completion
  and MainActor presentation cannot appear approved. Deterministic service/clock tests exercise
  those boundaries without waiting for the five-minute production deadline.

## Validation

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Xcode 27.0 (27A266a). Development app:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`, version 3.0.0, build 739.
It is not a distribution candidate. Logs and result bundles use `build/qa-v3-cycle84-*`.

Focused validation passes **111 tests / six suites**, zero failures, in **6.548 seconds**
(`focused-fixed.{log,xcresult}`). The selection comprises MCPServerCoreTests,
AutomationOperationRegistryTests, AutomationPatchReviewTests, FFmpegWhisperSetupModelTests,
FFmpegWhisperTranscriptionProviderTests and FFmpegWhisperJobRunnerTests. Commands use
`xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -configuration Debug
-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2`, unit scheme
`Aagedal Photo Agent Tests`, and one `-only-testing:` selection per suite.

Native smoke validation passes **three workflows**, zero failures/skips, in **123.317 seconds**
(`native.{log,xcresult}`). The same Xcode command uses scheme `Aagedal Photo Agent UI Smoke Tests`
and the CoreWorkflowSmokeTests methods `testAutomationPatchApprovalRevokesAndRefusesChangedPhoto`
(40.506 s), `testCustomWhisperFileBookmarksSurviveRelaunchWithoutConsentAndClearPermanently`
(61.289 s), and `testCustomWhisperOptionsPersistWithoutApprovingOrChangingTranscript` (21.522 s).
The new workflow enters Norwegian language (`no`), requests English translation, toggles GPU,
relaunches, verifies persisted controls with reset consent, and verifies byte-identical photo,
WAV, relationship and approved sidecar. These are generated disposable fixtures with isolated
Whisper preferences; no real-model translation or GPU inference is claimed. The driver still emits
DisplayManager diagnostics; passing assertions do not close display/accessibility release gates.

The actual embedded helper passes persistent-pipe initialization, pipelining, malformed-input
recovery, provider discovery, operation argument refusal and explicit unavailable-executor capability
checks; it discovers 15 tools and exits cleanly with zero stderr bytes (`helper.{json,log}`). SHA-256:
`326131cd4b8dff9ac61e1dd4f90c28e9ba3a34b516bebe48efa10c365d7f0024`.
The command is `python3 scripts/ci/probe_mcp_helper.py '<app>/Contents/MacOS/photo-agent-mcp'
--output build/qa-v3-cycle84-helper.json`. It does not change user authorization preferences.
`scripts/ci/validate_repository.sh` passes (`repository-final.log`); the manual checklist retains
36 unique cases, with no unrun case marked passed.

The first authorized build found a Swift Testing macro converting a Sendable closure into a
non-Sendable generated parameter. Unwrapping the provider after constructing it fixes that test
compilation error without changing assertions. The successful focused run includes this fix.

The first sandboxed Xcode command could not access compiler/package caches;
its failure is environment setup evidence, not a source or test failure. The authorized rerun uses
the normal host compiler caches and macOS test services.

The complete integrated regression passes **3,209 tests / 336 suites**, zero failures, in
**128.636 seconds** (`full.{log,xcresult}`). It uses the same unit Xcode command without
`-only-testing` filters and validates the source committed as `d0376b8`. Documentation was finalized
afterward. Independent operation and Whisper reviews found no remaining actionable source defects.
No test assertion was weakened, and no broad release gate is newly closed.

## Remaining before release

1. Connect production face-scan, metadata/Develop-template, batch transcription and guarded IPTC
   executors to durable admission/status/cancellation. Finish exact-plan commit authority, verified
   semantic read-back, physical preservation, per-photo outcomes and recovery/liveness integration.
2. Deliver the reproducible expanded FFmpeg artifact, trusted model lifecycle, licenses/notices and
   package-size evidence. Validate real-model accuracy, silence, language/translation, GPU/offline,
   failure/cancellation and supported client workflows. Custom options do not replace this work.
3. Complete authentic Sony/RAW/C2PA and external metadata interoperability, real transfer servers,
   iCloud/multi-Mac, interruption/recovery, accessibility, monitor/HDR/map/report and performance
   validation. Conditional AI-origin model work still requires its explicit product decision.
4. Obtain qualified privacy/legal review and protected remote CI evidence, then build and review the
   exact signed/notarized release candidate and complete final user acceptance. No package is published.
