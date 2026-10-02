# Cycle 122 — installed native review qualification and fresh shared authority

Baseline: `fe853a8`, initially clean. Production authorization fix: `1acfecf`.
Installed qualification implementation: `a34f612`. Final verification ran the same
14 code/test/project/probe files uncommitted atop `1acfecf`; their hashes match
these implementation commits. Documentation changes followed verification.
State remains **IMPLEMENTING**. Sub-agents owned shared authorization persistence,
the installed helper/UI qualification case, independent review and this report.
The parent owned integration, actual builds/native qualification, fixture diagnosis,
final evidence reconciliation and commits. No publication, automation schedule,
production authorization grant, user photo or model change was made.

## Implemented behavior

- Authorization reads synchronize their CFPreferences domain before consulting the
  cached value. A connected helper therefore observes app-side disablement, root
  removal and fresh revoke/regrant generations. Absent records stay default-off;
  malformed JSON and wrong preference value types refuse authorization.
- Preference read and write closures can throw without changing existing injected
  call sites. Saves refresh before setting the new blob and report a failed flush.
  A process-wide lock protects the pending preference value. If persistence fails,
  the dirty authorization blob is cleared before releasing that lock: a later read
  cannot flush an unacknowledged grant or restore older enabled authority after
  failed revocation. Settings mutation failures propagate to their caller.
- A new native workflow exercises the actual development-signed nested
  `photo-agent-mcp` executable against its exact running app bundle. It uses the
  production socket client/listener, signature requirements, kernel audit-token
  peer checks and retained request resolver. Authentication is never injected.
  See [ADR-006](../adr-006-authenticated-native-review-handoff.md).
- Disposable Debug-only configuration relocates authority, plans, requests,
  operations and the listener directory. The app bootstraps retained intent before
  listener startup, and Settings uses the same fixture authority. Invalid requested
  helper fixture launches and Release-build helper requests exit rather than falling
  back to host stores. This configuration changes storage routing, not normal folder admission.
- The installed workflow first refuses a wrong epoch without selecting review,
  then opens the exact retained request. It reviews the deterministic provider
  preparation without submitting execution. A subsequent wrong epoch must preserve
  the checked native consent; another accepted presentation must reset it. All helper
  acknowledgments retain false consent, execution, direct-executor and completion
  claims and no operation identifier. Source/WAV/relationship bytes and durable
  authorization/plan/request files must remain unchanged, with no operation or draft.
- XCTest's generated runner remains sandboxed. An external CLI launches the actual
  nested helper normally, outside the runner's inherited sandbox. A private token
  and call-number-bound JSON rendezvous coordinates requests/results only. The runner
  has one explicit read/write exception for `/private/tmp/apa-installed-qualification/`;
  the orchestrator checks that its actual codesign entitlements contain that exact exception
  and `com.apple.security.app-sandbox = true`. Application/helper sandbox settings are
  unchanged. The orchestration pins the app/helper hashes, verifies their signatures,
  checks protected fixture bytes around each helper invocation and records responses.
- Fixture routing retains `Darwin.realpath`'s physical canonical spelling. Foundation
  resolves an existing `/private/tmp` fixture through the `/tmp` symlink; private durable
  stores correctly refuse that path during their `O_NOFOLLOW` walk. Keeping the physical
  root fixes fixture initialization without relaxing production no-follow validation.
  The qualification now sends the actual Command-Q quit command and waits within a
  bound for the app to stop before checking listener teardown. The probe removes only
  inert fixture socket directories after confirming teardown. Production termination
  behavior is unchanged; its existing app-delegate callback stops the listener.

## Scope limits

The new installed case qualifies authenticated review presentation, exact request
selection and consent lifecycle; it never submits provider execution or publishes a
draft. Other native execution workflows use synthetic recognition and generated
fixtures. Neither establishes real Apple/Whisper inference, offline locale/device
behavior, model lifecycle, distribution signing/notarization or direct helper
execution. The pair uses development signing. Broader server/cloud/hardware,
accessibility, recovery, performance, privacy/legal and release acceptance gates
remain open. No whole Phase 5A or release-readiness criterion closes, and no Release
candidate or distribution artifact was built.

## Verification

Environment: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a),
Debug 3.0.0 build 739. App:
`build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
All installed/native fixtures are disposable generated data and isolated stores.
The shared preferences probe uses unique `com.aagedal.mcp-authorization-probe.*`
domains and removes their authorization records; it never accesses the production
preferences domain. No user authorization, photo, provider setting or model changes
are required by either probe.

- The focused authorization/native verification passes **96 tests / four suites**,
  zero failures, in **2.219 seconds** (`build/qa-v3-cycle122-focused-final.{log,xcresult}`).
  This earlier focused run covers failed refresh and settings mutation failure;
  the final integrated suite supersedes it after dirty-cache grant/revocation
  parameterization and the physical fixture correction.
- The independent-process CFPreferences probe passes **10 checks**
  (`build/qa-v3-authorization-preferences.json`). It compiles exact production value
  declarations/store code into a temporary CLI. A warm reader remains alive while
  independent writer processes grant, disable, regrant, remove roots, corrupt/change
  the record type and delete authority. Unobserved revoke/regrant rotates retained
  authority; failed pending grants do not appear after a normal refresh; a restarted
  reader observes the same durable generation. These are 10 assertions using multiple
  independent processes, not a claim that the installed helper used test preferences.
- The final integrated run passes **3,780 tests / 369 suites**, zero failures/skips,
  in **133.794 seconds** (`build/qa-v3-cycle122-full-final.{log,xcresult}` and
  `-summary.json`). It includes the physical fixture correction and real private
  request-store regression. Earlier `-full` evidence passed in 129.703 seconds
  before that correction and is superseded. Four summary QoS warnings retain
  the broader responsiveness gate; 340 host cache `MDB_MAP_FULL` log messages
  remain environment observations.
- The final actual bundled helper probe passes **31 tools**, persistent/pipelined
  protocol recovery and truthful executor boundaries, exit zero and zero stderr
  (`build/qa-v3-cycle122-helper-final.{json,log}`). Its helper hash matches the
  final installed-pair helper identified below. Earlier unsuffixed helper evidence
  is superseded.
- Final existing native regression passes **four tests in 133.033 seconds**,
  zero failures/skips (`build/qa-v3-cycle122-ui-regression-final.{log,xcresult}` and
  `-summary.json`): changed-source refusal 30.534 seconds; concrete-provider consent
  and synthetic draft completion 39.873; dismissal, cancellation, saved prefix and
  relaunch 48.329; presentation-only exact review without consent 14.297. Combined
  with installed qualification below, five final-source workflows pass across two
  runs in 160.970 seconds. The earlier `-ui-final` five-case run failed its installed
  case and is superseded; its four earlier passes are not the final evidence.
  Native summary diagnostics include six `NSStackView` constraint warnings and
  four main-thread responsiveness warnings. Assertions pass, but broader layout
  and performance qualification remains open.
- The actual signed external installed-pipeline run after physical fixture correction
  executes all **four helper invocations**, exit zero and zero stderr, with the expected
  two wrong-epoch refusals and two exact `reviewRequired` responses. Native selection,
  consent preservation and repeated-presentation consent reset reach their assertions.
  The test then **fails its final shutdown assertion** in **27.108 seconds**
  (`build/qa-v3-cycle122-installed-physical.{json,log,xcresult}`). Its JSON correctly
  records `passed = false` and `cleanupComplete = false`; the stale socket is preserved.
  This is partial installed-path evidence, not a passing qualification. The corrected
  graceful-quit case passes as recorded below.

- Final installed qualification passes **one native test in 27.937 seconds**,
  zero failures/skips, and **four actual bundled-helper invocations**, exit zero
  and zero stderr (`build/qa-v3-cycle122-installed-final2.{json,log,xcresult}`).
  Both stale epochs refuse; both original epochs return truthful `reviewRequired`
  with no operation, consent, execution or completion claim. Native exact selection,
  provider review, consent preservation on refusal and consent reset on acceptance
  pass. Command-Q stops the app and removes its listener; `cleanupComplete = true`.
  The actual runner is sandboxed with exactly the documented fixture exception.
  Tested app executable SHA-256: `610ce441ac6859eade8790666d3ee7687c23f8dc31a24567761488623ed3dae3`;
  nested helper: `7cb8bc8a0404c336c4b94ed2149f79b7cbd5d8693f3c60d672d1613e5a56c016`.
  Subsequent Xcode rebuild signatures may change bytes while source hashes stay fixed.
- Seven explicitly identified stale directories from prior forced XCTest termination
  were removed only after retained no-follow ownership/inode checks, an exclusive
  owner lock and a concrete refused connection. No live or unexpected endpoint was
  deleted (`build/qa-v3-cycle122-stale-cleanup.json`). The dedicated empty shared
  parent remains owned/private by design.
- Repository validation passes (`build/qa-v3-cycle122-repository-final.log`).
  The updated HTML checklist has 40 complete unique cases with existing source
  references; embedded JavaScript syntax passes. All 453 local links across seven
  changed Markdown documents pass (`build/qa-v3-cycle122-doc-checks.json`). A25 adds the review-only signed
  pair/client procedure, with candidate and human results still unassigned/unrun.

Independent review identified the stale CFPreferences cache, unreported write failure,
dirty failed grants, fixture bootstrap ordering, Settings' mismatched fixture authority
and installed listener cleanup. The implementation and focused regressions address
those findings. Independent final diff review finds no must-fix issue and confirms the actual
installed evidence, unchanged production authentication and narrow runner sandbox.
Final helper/native regressions pass. All 14 frozen hashes match implementation
commits `1acfecf` / `a34f612`; no application source change followed final verification. The final
14-file source snapshot is `build/qa-v3-cycle122-source-hashes-final.json`; the earlier
unsuffixed snapshot is superseded.

Failed attempts remain in the ignored evidence tree. Initial `-installed-ui*` runs
exposed inherited runner sandbox/helper diagnostics and a failed acknowledgment.
The `-installed-ui-unsandboxed` filename records an attempted diagnostic configuration,
not a qualification that removed sandbox protections. Final orchestration keeps the
runner sandbox enabled and launches the helper externally. Earlier `-installed-final`
and `-installed-shared-final` attempts also failed and cannot establish qualification.
`build/qa-v3-cycle122-installed-diagnostic2.json` records zero helper calls and
`MCPVoiceTranscriptionPlanStore.Failure.storageUnavailable` during fixture initialization,
with the narrow runner exception and sandbox enabled. The physical path correction
addresses this concrete private-store refusal. Early source/probe compilation and
optional security bookmark sandbox diagnostics are separate from successful
independent-process preference evidence and do not establish installed authentication.
The subsequent physical run exposes XCTest's forceful `app.terminate()` shutdown,
which skips the existing AppKit termination callback. The test now uses Command-Q
and a bounded stopped-state wait; this corrects the qualification method without
changing production teardown or deleting a live/stale listener to mask failure.

Reproduction:

```sh
python3 -B scripts/ci/probe_mcp_authorization.py \
  --output build/qa-v3-authorization-preferences.json
python3 -B scripts/ci/probe_installed_native_review.py \
  --app 'build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app' \
  --derived-data-path build/qa-v3-whisper-lifecycle-derived \
  --result-bundle build/qa-v3-cycle122-installed-final2.xcresult \
  --log build/qa-v3-cycle122-installed-final2.log \
  --output build/qa-v3-cycle122-installed-final2.json
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/qa-v3-whisper-lifecycle-derived \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  -resultBundlePath build/qa-v3-cycle122-full-final.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

The installed probe owns the dedicated
`testSignedBundledHelperOpensExactTranscriptionReviewWithoutExecution` selection.
Running that case without the external orchestrator explicitly skips it rather
than claiming installed qualification. The other four native selections are those
listed in [cycle 121](cycle-121-authenticated-native-review-2026-10-02.md).
Each reproduction needs a fresh result-bundle path when earlier evidence exists.

## Next work

Implement guarded direct helper
execution through exact fresh native consent, retained rooted authority and durable
operation linkage, preserving non-replay and truthful completion. Qualify real
providers, offline/device behavior and signed model lifecycle; connect remaining
face/template executors and broaden recovery. Preserve external interoperability,
server/cloud/hardware/accessibility, performance, privacy/legal, remote-CI and exact
signed-candidate/user acceptance gates.

## Final source identity

The following hashes identify final code/test/project/probe source at verification,
independent of development signature changes across rebuilds. These hashes match
the implementation commits and were rechecked after final native verification.

| File | SHA-256 |
| --- | --- |
| `Aagedal Photo Agent Tests/MCPNativeInvocationToolTests.swift` | `ef3a7a802f05b91fc8d0bda8e74cda785596347fe522055176f387103cb44ae6` |
| `Aagedal Photo Agent Tests/MCPServerCoreTests.swift` | `de50ecdb0205072f2922f8bd10a99d320063d1624c647c896d1a8ed982e780b7` |
| `Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests.swift` | `bab32e7408e4851a2b29d1b2ad25132a6cf38543206a39c658d2f6616f307588` |
| `Aagedal Photo Agent UI Smoke Tests/InstalledHelperQualification.entitlements` | `20c966e0b9cbf8642dee160a11559a1267ad60d85888d97795289328155fdbbe` |
| `Aagedal Photo Agent.xcodeproj/project.pbxproj` | `52114bc1905cd8fe882b17cb2b1231980e2ffe1255258748d569ddfdc53220d0` |
| `Aagedal Photo Agent/Aagedal_Photo_AgentApp.swift` | `e3e67613ba67c29ab13e3e558e0d2e6862711bbaa84e454a381b96f501392d80` |
| `Aagedal Photo Agent/Services/Automation/MCPServerCore.swift` | `812934261c60f6c98807067550f5fd5740d2f7d6556f7ae8b4ce88e307e64b42` |
| `Aagedal Photo Agent/Services/Automation/UITestNativeInvocationConfiguration.swift` | `f54d552d41db86496f7fcc4386f50bbf28014f7fabb5bb93faf8d8c768e8c03c` |
| `Aagedal Photo Agent/Utilities/UITestTranscriptionReviewFixture.swift` | `39830928375d7282e05e621b79ebb25b2626d2a6693f79cff75fbf78e6d63f69` |
| `Aagedal Photo Agent/ViewModels/AutomationNativeInvocationController.swift` | `ebbc47a7e90d6ffc58d053d1ab1c6412f8a3ab703a8e77589c94cae5ba6861ee` |
| `Aagedal Photo Agent/Views/Settings/AutomationSettingsView.swift` | `550ae817aefda6f7b2a96a8c64bd9efb21ed60bc9c483b125a6dc524b87c7eaf` |
| `PhotoAgent MCP/main.swift` | `ac737b7c5809c79ce6dfc5dd9712603df1e3e2fcd479e6822ed14b9b57c0458b` |
| `scripts/ci/probe_installed_native_review.py` | `31a044d88cf94418bed9b20c6c0265be34e57939a4804dcd72127c696b4e6939` |
| `scripts/ci/probe_mcp_authorization.py` | `1bd64e2b5f8a150a288519adda3b70878a7b7a07e2249caa4d0fbfa2a5b5fbd4` |
