# Cycle 81 — retained Whisper selections and provider discovery

Baseline `e192944`, initially clean. Two implementation agents and one native-test agent
worked alongside coordinator integration, documentation and validation. Independent review
covered bookmark cancellation/lifetime, test isolation, provider claims and the transport probe.
Implementation, tests and public documentation are committed as `e9b0007`.
Readiness remains IMPLEMENTING.

## Implementation

- Custom FFmpeg and model selections persist as read-only security-scoped bookmarks.
  Caption restores them asynchronously without prompting or mounting volumes. Stale bookmarks
  refresh after successful resolution; missing files and failed refresh preserve recovery evidence
  without enabling a provider. Clear Custom Files removes both saved selections.
- Closing Caption ends the access session and revokes consent/admission. Every reopened session
  needs explicit execution consent and fresh identity admission. Providers retain access until
  inference teardown. Generation checks refuse late selection/restore publication after Clear,
  reselection or session closure. Bookmark filesystem work uses a dedicated serialized executor.
- MCP adds `list_transcription_providers` with stable Apple Speech/custom Whisper IDs and
  actionable setup guidance. It truthfully reports runtime/language/model availability as unknown
  outside the app session, and exposes no transcription execution. This is catalog discovery,
  not completion of the full provider-readiness or production-operation criteria.
- A committed `scripts/ci/probe_mcp_helper.py` exercises the actual executable with STDIN kept
  open: initialize, pipelined discovery/ping, malformed-input recovery, provider catalog and
  argument refusal, and clean EOF. It never changes settings or authorizes/opens photographs.
  Explicit checks remain active with optimized Python.
- Native smoke tests use a gated, isolated preferences suite retained across relaunch and cleaned
  at teardown. Disposable executable/model files are selected in real file panels; setup only
  captures identities and does not execute either file. Public help/privacy/limitations and the
  unrun human acceptance checklist now explain persistence and per-session consent.

## Validation

Focused unit validation passes **56 tests / two suites**, zero failures, in **1.347 seconds**:
`MCPServerCoreTests` and `FFmpegWhisperSetupModelTests`. The latter now has 11 setup tests,
including real bookmark restoration, stale/missing/refused refresh, changed-model readmission,
late publication refusal and provider security-scope lifetime. Repository validation passes.

Two native workflows pass using disposable generated image/WAV/sidecar and custom-file fixtures:

- `testCustomWhisperFileBookmarksSurviveRelaunchWithoutConsentAndClearPermanently` passes
  in **62.892 seconds**: select both files via native pickers, consent, hash-only preparation,
  relaunch, restore filenames without consent, require fresh consent, Clear and relaunch again.
  Image/WAV/relationship/review and both selected artifact bytes remain unchanged.
- `testCustomWhisperSetupRequiresFilesAndConsentWithoutChangingReview` passes in
  **30.460 seconds**: unavailable setup and both picker cancellations preserve the approved review.

The first new native test failed because its assertion cast the checkbox accessibility value only
as a String. The corrected test accepts exact NSNumber or string boolean values; absent/unrecognized
values still fail. The affected workflow passes on rerun. This was a test-driver correction.
No custom inference or real-model quality claim is made by these native setup tests.

The actual bundled helper passes the committed probe, including optimized Python execution:
12 tools, persistent STDIN, ordered pipelined requests, invalid-input recovery, real provider
catalog/argument refusal, clean EOF and zero stderr bytes. SHA-256:
`176b2a13170b2650751ba7939774a2b1d0643677112e64c32502124f881536a7`.
The probe covers executable protocol behavior, not all supported external clients.

The complete integrated unit suite passes **3,169 tests / 333 suites**, zero failures,
in **129.550 seconds**. Final repository validation and independent source review pass.
Known LMDB map-size and system display/QoS diagnostics remain observations; assertions were
not weakened. The custom retained-bookmark implementation criterion is now complete; no broad
release-readiness gate is newly closed.

Initial sandboxed Xcode access was denied required compiler-cache writes. Approved execution
then caught Swift 6 restrictions on semaphore waits in the new async test code. The test helper
now resumes a checked continuation from a Dispatch worker; the production implementation was
not weakened. Independent review also prompted the dedicated bookmark executor and explicit
Python validation checks.

## Remaining before release

Guarded IPTC approval, physical preservation/write verification and recoverable commits;
production MCP operations, live provider readiness, status/cancellation and supported-client
workflows; curated signed model delivery and bundled Whisper artifact/licensing/size packaging;
real-model accuracy, additional audio formats and native inference/offline/failure acceptance;
authentic Sony/RAW/C2PA and external metadata interoperability; real servers, iCloud/multi-Mac,
interruption, accessibility/display/map/report and performance evidence; qualified legal/privacy
review and protected remote CI; exact-candidate package/review and final user acceptance.
Signing/notarization/distribution remain separately authorized release steps. General llama.cpp/GGUF
remains 3.1. These changes do not claim a release-ready candidate.

## Reproduction and evidence

Xcode commands use `Aagedal Photo Agent.xcodeproj`, Debug, `-destination 'platform=macOS'`,
`-parallel-testing-enabled NO -jobs 2`. Unit scheme: `Aagedal Photo Agent Tests`, with
`-only-testing:'Aagedal Photo Agent Tests/<suite>'` for the focused suites above. Native scheme:
`Aagedal Photo Agent UI Smoke Tests`, selected with
`-only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/<method>'`.
The full unit run omits test selection. Repository command: `scripts/ci/validate_repository.sh`.

Host: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a). Tested app: version 3.0.0, build 739:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Native fixtures are generated beneath the UI runner's temporary directory and removed at teardown;
the app is terminated and isolated Whisper preferences removed. The tested source was baseline plus
this cycle's implementation diff; no release artifact was published.

Ignored evidence: `build/qa-v3-cycle81-{focused-approved,focused-final,native,native-final,full}.log`
and corresponding `.xcresult` bundles, `build/qa-v3-cycle81-repository-final.log`, and
`build/qa-v3-cycle81-helper.json`. Run the helper probe with
`python3 -O -B scripts/ci/probe_mcp_helper.py <app>/Contents/MacOS/photo-agent-mcp --output <evidence.json>`.

A project-file record-order change appeared during the session without agent ownership.
Parsed property-list comparison with HEAD confirms identical semantics; it is left uncommitted.
