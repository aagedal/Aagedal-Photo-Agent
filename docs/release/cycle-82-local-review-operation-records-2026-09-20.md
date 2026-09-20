# Cycle 82 — local plan review and operation records

Baseline `cb0e5f2`, initially clean. Two implementation agents worked on disjoint approval
and operation-record services while the coordinator implemented Settings review and integration.
A third agent independently reviewed the changes. Implementation is committed as `7dfd0ae`.
Readiness remains IMPLEMENTING.

## Implemented behavior

- Settings → Automation → Proofreading Plan Review accepts an exact opaque plan ID.
  A serialized background worker uses the existing plan revalidation boundary before displaying
  normalized before/proposed values, literal Unicode, quoted repeatable-value boundaries,
  compatibility/preservation warnings and expiry. Editing the ID, clearing or leaving the view
  removes the displayed review; cancelled/superseded requests cannot republish it.
  It is a checked snapshot, not live monitoring, approval or a write operation.
- A native-only, process-lifetime approval store binds the exact plan preview, original deadline,
  captured authorization and creation time. Non-Codable reviews/receipts prevent remote boolean
  confirmation or copied tokens from creating local consent. Expiry, clock rollback, cross-session
  use, revocation and detected drift refuse; detected drift permanently revokes the receipt.
  This API is internal pending native consent and retained writer integration. Successful validation
  alone is not authority for a later write; the future executor must check inside mutation admission.
- A private bounded operation registry records queued/running/completed/cancelled state, cancellation
  requests, owner identity and verified/failed/cancelled/partial-uncertain/recovery-required/stale
  outcomes. Cancellation requests do not claim that work stopped. Only an owner may acknowledge or
  finish work. Restart preserves unresolved state instead of inventing success/cancellation.
  Closed operation-kind identifiers keep filenames and metadata out of records. Shared nonblocking
  file locking spans reload/update/atomic replacement; corrupt or unsupported archives and unsafe
  filesystem entries refuse without overwriting evidence.
- A gated native-test fixture creates a disposable JPEG, uses private in-memory authority and plans,
  and prepares the exact preview through production services. Setup errors never fall back to user
  preferences or the user's patch-plan archive. Normal launches cannot enable this fixture.

## Scope still open

No approval, commit, operation-status or cancellation MCP endpoint is added. Native explicit approval,
production executor integration, authorization of status/cancellation, orphaned-operation recovery,
per-photo outcomes, physical preservation and verified semantic read-back remain required.
The registry is a coordination primitive, not a claim that production operations are implemented.
No broad release gate is newly closed.

Curated signed model delivery and bundled FFmpeg/Whisper artifact/licensing/size packaging remain,
along with real-model accuracy and offline/failure acceptance, additional admitted audio formats,
supported-client workflows, authentic Sony/RAW/C2PA and external metadata interoperability,
real servers, iCloud/multi-Mac, interruption, accessibility/display/map/report and performance evidence,
qualified legal/privacy review and protected remote CI, exact-candidate package/review and final user
acceptance. Signing/notarization/publication remain separate authorized distribution steps.

## Validation

Focused validation passes **31 tests / four suites**, zero failures, in **0.657 seconds**.
This includes exact-photo set/clear review, revocation, consent lifecycle, operation storage refusal
and presentation/fixture gating. The later isolated fixture-cache change is covered by native and
complete regression below. Evidence is retained under ignored
`build/qa-v3-cycle82-*` paths. The first sandboxed Xcode command could not write compiler caches;
approved Xcode execution uses the existing host cache and test services. An intermediate compilation
started before the final fixture flag landed and failed against that older compiled module; it is
not candidate evidence. Final checks use frozen source.

Reproduction: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'` with Debug,
`-destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2` and unit scheme
`Aagedal Photo Agent Tests`. Focused suites: MCPIPTCPatchApprovalStoreTests,
MCPIPTCPatchPlanStoreTests, AutomationOperationRegistryTests and AutomationPatchReviewTests.
Native scheme: `Aagedal Photo Agent UI Smoke Tests`, selected CoreWorkflowSmokeTests methods
`testAutomationPatchReviewRefusesInvalidPlanWithoutChangingPhotos` and
`testAutomationPatchReviewDisplaysExactPlanAndRefusesChangedPhoto`.
Repository command: `scripts/ci/validate_repository.sh`. Helper probe:
`python3 -B scripts/ci/probe_mcp_helper.py <app>/Contents/MacOS/photo-agent-mcp --output <evidence.json>`.

Independent review caught repeated SwiftUI reference-model construction overwriting the test
manifest with a discarded fixture's plan. The fixture service now caches one success or failure
per test process, and navigation coverage compares the stable manifest. The reviewer confirmed
resolution with no remaining actionable findings. First native attempts caught test-driver issues:
an ambiguous General label and error text exposed as an accessibility value instead of a label.
The tests now select the unique Shortcuts row and require the exact error in either text channel;
no product assertion was removed.

Both final native workflows pass: exact-plan review with Unicode/set/clear, Clear/navigation,
stable fixture identity and changed-source refusal; invalid-ID error feedback and clearing.
All inspected JPEG bytes remain unchanged and no sidecars are created by review. Native fixtures
are generated beneath the UI runner's temporary directory and removed at teardown; app termination
also disposes their in-memory authority and plans. No user automation preference is changed.

Host: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a). Tested development app: version 3.0.0,
build 739 at `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
This is a development build, not a release candidate offered for final acceptance.

## Final results

The complete final-source regression passes **3,189 tests / 336 suites**, zero failures,
in **121.878 seconds**. Native valid-plan/navigation/changed-source coverage passes in **27.449
seconds** and invalid-ID/clear coverage passes in **18.010 seconds**. Repository validation and
staged whitespace checks pass. The 36-case checklist JSON remains valid with unique IDs; A21
now includes native plan inspection. This does not substitute for opening the final candidate's
human checklist or completing its unrun acceptance cases.

The final actual-helper probe discovers all 12 existing tools with read-only annotations and
passes persistent STDIN, pipelined requests, malformed-input recovery, provider discovery/argument
refusal, clean EOF and zero stderr bytes. It does not invoke every discovered tool.
Helper SHA-256: `7dccfdf258287d2dc9e1acbbd79132bc6f113800e7aad635a521a8702bfc67af`.
No new helper mutation endpoint is advertised. Known test-host LMDB map-size and system display/
QoS diagnostics remain observations; no assertions were weakened to accommodate them.

Evidence: `build/qa-v3-cycle82-focused-stable.{log,xcresult}`,
`build/qa-v3-cycle82-native-final.{log,xcresult}`, `build/qa-v3-cycle82-full.{log,xcresult}`,
`build/qa-v3-cycle82-repository-final.log` and `build/qa-v3-cycle82-helper-final.json`.
The full run uses exactly the source committed as `7dfd0ae`; documentation was finalized afterward.
No release package was published and no external-service or hardware gate is claimed complete.

Independent final evidence audit confirmed the recorded counts/timings and open-gate accounting.
Its helper-probe wording correction is incorporated above.
