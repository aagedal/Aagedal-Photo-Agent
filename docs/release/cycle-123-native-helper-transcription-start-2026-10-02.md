# Cycle 123 — one-use native helper transcription start

Baseline: `86ac666`, initially clean. Implementation commit: `1e023cf`. All frozen implementation/test/probe hashes below match that commit.
State remains **IMPLEMENTING**; no Release candidate or whole readiness gate closes.
Sub-agents implemented the guarded start and real-provider probe, audited release requirements
and independently reviewed the consent boundary. The parent integrated fixes, ran final native
and automated verification, reconciled documentation and committed the work. No publication,
automation change, model download, production authority grant or user-photo mutation occurred.

## Implemented behavior

`start_voice_transcription` accepts only canonical original request/epoch handles through the
existing mutually authenticated signed-pair socket. The user must review concrete provider,
options and prepared sources, check native consent and explicitly allow one helper start.
An in-memory grant expires after 60 monotonic seconds and is revoked on withdrawal, provider
change, review or dismissal. Synchronous provider-selection comparison also refuses drift before
SwiftUI observers run. Consumed grants cannot be renewed by toggling consent. No consent,
provider configuration, paths or transcript text crosses the wire.

A one-second MainActor handoff prevents queued timed-out work from consuming a grant later.
The grant is consumed before asynchronous submission through existing rooted reservation,
admission, durable linkage and anchored draft execution. `executionRequested` acknowledges
scheduling only: admission, execution and completion remain false, with no operation ID.
Clients inspect retained history; an exact linked retry returns the original operation handle
without execution. See [ADR-006](../adr-006-authenticated-native-review-handoff.md).

The installed qualification adds an explicit execution mode while preserving review-only default.
Its report verifies durable admission/owner/kind/linkage/completion and two unapproved drafts;
transcript text is excluded. It reports observed completion independently of later test failure.
Production authentication and sandbox settings are unchanged. The runner retains its existing
single private fixture-directory exception; the actual nested helper runs outside XCTest's sandbox.

The standalone real-provider probe compiles complete unchanged production Swift runner,
provider, parser, output reader and provenance sources, plus the exact transcription error
declaration, with strict Swift 6. It requires supplied local artifacts and downloads nothing.
Ten real inference/lifecycle/refusal cases and nine probe self-tests are reproducible through
`scripts/ci/probe_whisper_provider.py`. Five installed-probe self-tests verify report evidence.

Independent review found and resolved consent withdrawal/recheck reuse, wall-clock expiry,
provider-selection observer race and retained view closure issues. Tests cover those boundaries,
wrong handles, checkbox-only refusal, busy/expired grants, timed-out handoff and truthful status.
The helper catalog exposes the specific start capability while retaining unknown runtime provider
readiness and unfinished broader executor claims. Help, privacy, limitations and manual A26
now describe the exact native one-use workflow.

## Final verification

| Check | Evidence and result |
| --- | --- |
| Integrated suite | 3,787 tests / 369 suites, zero failures/skips, 126.433 seconds; `build/qa-v3-cycle123-full-final.xcresult` |
| Focused consent/channel/catalog suites | 154 tests / six suites, zero failures, 21.514 seconds; `build/qa-v3-cycle123-focused-final.xcresult` |
| Actual installed signed-helper execution | One test, zero failures/skips, 40.478 seconds; nine real calls; `build/qa-v3-cycle123-installed-execution-final.json` and `.xcresult` |
| Existing native regressions | Four tests, zero failures/skips, 131.618 seconds; `build/qa-v3-cycle123-native-regression.xcresult` |
| Bundled helper protocol | 32 tools, persistent/pipelined malformed recovery and consent-argument refusal; `build/qa-v3-cycle123-helper.json` |
| Real production Whisper CLI | Ten passing cases; `build/qa-v3-provider-production-cli-final-20261002/report.json` |
| Actual Apple Speech | One skip, zero failures, 22.289 seconds: missing `en_US` on-device language asset; `build/qa-v3-cycle123-apple-native.xcresult`. Open gate, not a pass. |
| Probe self-tests | Five installed-report tests and nine real-provider-probe tests pass |
| Repository checks | `build/qa-v3-cycle123-repository-final2.log` passes; `git diff --check` passes |
| Checklist | 41 unique cases with complete JSON fields and existing local source links; extracted JavaScript syntax passes. Interactive browser QA remains blocked by explicit local-file URL policy; no alternate route used. Candidate unassigned and human results unrun. |

The installed nine-call sequence refuses stale review handles, clears consent on exact review,
refuses start without a grant and with a checkbox only, refuses a wrong epoch while preserving
the valid grant, consumes it once, observes durable verified two-draft completion, and returns
the original linked operation without modifying retained bytes on retry. Source/WAV/relationship,
plan and authority bytes remain unchanged. Normal Command-Q stops the listener and cleanup is
complete. Recognition is synthetic; this does not qualify actual native Apple/Whisper inference.

Real production CLI cases cover CPU English, automatic language, no speech, deadline, cancellation
of an observed live child with reaping, changed audio/model/executable identities, revoked final
authorization and GPU-request provenance. All report no stranded jobs/processes. The GPU-request
case establishes option plumbing/provenance, not GPU acceleration. Reports contain no transcript.
Model and executable identity/payload checks do not qualify signed descriptor distribution or
native Settings lifecycle.

The first focused build exposed two missing `try` annotations in added tests; corrected before the
passing run. The first installed execution reached verified drafts but failed a test assumption
that a computed operation ID was stored at the document top level. Production stores it inside
`admission`; assertions and report validation were corrected and self-tests now mirror that actual
shape. That earlier run remains failed with incomplete cleanup and is superseded by the final
passing nine-call run. Initial sandbox Xcode cache failures occurred before testing; subsequent
approved native/Xcode runs used the necessary host access. The provisional full run passed
3,787 tests before final description/assertion edits; only the final run below qualifies final source.

Runtime diagnostics remain follow-up evidence for performance/UI qualification: `full-final`: 12 QoS warnings, 0 constraint warnings, 10 main-thread diagnostic warnings; `native-regression`: 0 QoS warnings, 0 constraint warnings, 4 main-thread diagnostic warnings; `installed-execution-final`: 0 QoS warnings, 0 constraint warnings, 1 main-thread diagnostic warnings. Passing assertions do not waive those gates.

## Exact artifacts and source identity

Installed Debug 3.0.0 build 739, arm64, Xcode 27.0 (27A266a), macOS 27.0.1 (26A434).
Installed app executable SHA-256: `735ef228195e39757781d0a00d2da5c024d7bffddadd0e5788a07a9a7c9f9073`.
Installed helper SHA-256: `5ceae75a28b141993adb4ce9ade52c49d2ab4763446552642ce189886b3525cd`.
These identify the observed installed qualification artifact, not a distribution candidate.

Real CLI FFmpeg SHA-256: `54f5d1c12e9d2a735059fed43f8f134ff24a527c295ec819cad77185db667c33`.
Base model: 147,951,465 bytes, SHA-256 `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`.
Synthetic speech WAV SHA-256: `1447653cdba67d0170638a7b0d43281289fe0b824522d62a6bad607ce79e75dc`.
The CLI report additionally pins all six source files/declaration and harness hashes.

Final changed implementation/test/probe sources were frozen for final verification:

| File | SHA-256 |
| --- | --- |
| `Aagedal Photo Agent Tests/AutomationTranscriptionReviewModelTests.swift` | `9b14a267e93ea22bcb70d14b42acc3764c94aaeb6580c3cadb77b839d89a31ca` |
| `Aagedal Photo Agent Tests/MCPNativeInvocationToolTests.swift` | `a3d5056e518131d309622ad69bd22ec3e84e31324071f633c0c6ec4b9bff54a7` |
| `Aagedal Photo Agent Tests/MCPServerCoreTests.swift` | `e6406a71c5adba6795aa9503e5ea6662a5ccf00beb683b8c64b0f62ddf60e317` |
| `Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests.swift` | `3e912826ed20664113f7d311d226d93d2914e753c2601479478493c6ea6ec7f7` |
| `Aagedal Photo Agent/Services/Automation/AutomationNativeInvocationChannel.swift` | `a88c464c188da9510054f239df48b01a737ed484689efa068b5707c7f583f44a` |
| `Aagedal Photo Agent/Services/Automation/MCPServerCore.swift` | `211eb6d150c2873543aaa8400aa0e918d77c3decdd56e9702afa455b68134134` |
| `Aagedal Photo Agent/Services/Automation/UITestNativeInvocationConfiguration.swift` | `b2735587494dc235c1fdf921c2126d213b5e75cea39a5efceeb1cb707f1474b4` |
| `Aagedal Photo Agent/ViewModels/AutomationNativeInvocationController.swift` | `dec36b4d6a4c11dff4cc6ef18926c0db2beb4a9c8a0788f7414baf7438514faf` |
| `Aagedal Photo Agent/ViewModels/AutomationTranscriptionReviewModel.swift` | `ba07045e48757a74ffccdbd0649875999f20f3d163508796b266b9031c2a31a2` |
| `Aagedal Photo Agent/Views/Settings/AutomationTranscriptionReviewView.swift` | `749373e3fadfe578a0924e229bc6a97695ba48f1c70b401caec87c863f09f2f8` |
| `scripts/ci/probe_installed_native_review.py` | `3586f5e9b4a765213d18bb982ce2373827e8440f19bf7ebb575474314c6eccfb` |
| `scripts/ci/probe_mcp_helper.py` | `8bb4a046a7e9d9a127f15f8dbfc8f520d5fd30faf4ce6250fb6446a97c788648` |
| `scripts/ci/probe_whisper_provider.py` | `3825fcb1f7a2238dd0d28f980a100fd1e5415f217371e28edd4831de16496843` |
| `scripts/ci/test_installed_native_review_probe.py` | `365b8b336344c5ed4620eb335a03c3d8403202447bd4bde6c32604a9e7d9f0ed` |
| `scripts/ci/test_whisper_provider_probe.py` | `e13a968838e766d719f0c015dcc563e7368d3d90a080fbc030e3e52a3e73ed89` |
| `scripts/ci/validate_repository.sh` | `9aec58d2501e5c9048966c4685a7cc123532a99d05cd24132d96f1437a544df2` |

## Remaining work and user handoff

Qualify actual native providers and signed model lifecycle, cancellation/relaunch/offline/device
behavior; complete remaining face/template executors and guarded physical IPTC tools; reconcile
all mandatory performance, recovery, external, hardware, accessibility, privacy/legal, CI and
candidate gates in the owning plans. This continuation closes no whole Phase 5A checkbox.

The [release completion handoff](release-completion-handoff-2026-10-02.md) names agent-owned
work, resources the user can prepare and later U01–U06 acceptance. The immediate observed
provider prerequisite is explicit English Apple Speech language download through Caption with
an associated memo. Final candidate acceptance is not ready. No secrets are requested in chat,
and publication remains a later separately authorized release-owner step.
