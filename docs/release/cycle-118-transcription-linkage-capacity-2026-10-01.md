# Cycle 118 — exact transcription operation linkage and cancelled-request capacity

Baseline: `ae1da87`, initially clean. Implementation is committed as `bfd8234`. All 13
application/test source hashes match that commit and the final verified source; no source changes
followed final verification. The parent owns integration, shared registry/executor
hooks, helper projection, native fixtures/tests, verification, documentation and commits.
One sub-agent owns the request admission/linkage store and tests; another owns the native
capacity model/view and tests. A third independently reviews the final source and evidence.
Chat inventory found no other active chat editing this checkout. State remains **IMPLEMENTING**.

## Implemented behavior

- An immutable, versioned admission binds the original request UUID/epoch, ordered intent
  digest/batch identity, a reserved operation UUID and exact owner UUID. Admission compares
  the complete expected retained record and refuses cancellation, expiry, retained-request drift or reuse.
  Operation history ownership precedes request storage, including cold history initialization.
  A failed outer history publication after private admission leaves non-replayable uncertainty.
- The retained coordinator enqueues the reserved UUID and refuses duplicate retained IDs.
  The batch executor configures ordered progress, then runs its linkage hook before any work
  is scheduled. The store reads the actual retained operation under history/request locks;
  exact operation/owner, kind, managed-history marker, queued items/count and chronology must
  agree. A kind/count/time match alone cannot substitute another operation. Failed admission
  or linkage never schedules recognition or draft saving. Interrupted admission cannot replay.
- Archive schema 2 strictly validates admission fields and chronology. Schema 1 remains
  readable without changing bytes and migrates only on mutation. Checksums remain corruption
  evidence, never authentication. Original handles and status-only request retries survive
  admission, expiry and epoch rotation. Post-admission cancellation retains admission/linkage;
  callers must forward durable cancellation to the operation registry before acknowledging it.
- Settings → Automation → Transcription Intent Review exposes bounded capacity and explicit
  **Remove cancelled transcription requests** confirmation. The dialog captures the displayed
  epoch; the store rechecks it before removing only proven pre-admission cancellations and
  rotating the current epoch. Awaiting, admitted, linked and uncertain evidence stays retained.
  No helper cleanup tool or automatic eviction is added. Retained requests keep original epochs.
- Native evidence polling preserves a selected review only while its exact request is unchanged.
  Cleanup, cancellation, changed intent, failed reads and navigation invalidate pending source,
  status and capacity completions. Confirmed cleanup cancels concurrent read-only polling.
  Successful status polling preserves a rejected source-review message until explicit refresh;
  retained intent equality cannot establish that changed photo/audio carriers became valid again.
  Off-main capacity service methods explicitly match protocol/default async signatures.
  Helper capacity truthfully advertises native cleanup; internal admitted/linked records expose
  separate coordination status and an operation handle only after linkage.

## Scope and authority limits

Lifecycle hooks are internal caller-supplied coordination closures. They do not bind the
prepared native photo set or selected provider/options/model/executable to rooted helper intent,
authenticate IPC, grant consent or authorize an inference download. No production inbox/helper
caller can invoke admission or execution through this milestone. The archived managed-owner
marker is not current owner-liveness evidence. Standalone linkage does not schedule work.
Actual Apple/Whisper inference, spoken VoiceOver and physical crash/archive-loss qualification
are not established by deterministic fixtures. No whole 3.0 release gate closes.

## Verification

Environment: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Debug 3.0.0
build 739. App: `build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app`.
All new fixtures are generated/disposable and use isolated authorization/archives; no user
photo roots or provider/model installation are involved. Exact command lines are retained at
the beginning of each test log. Source hashes are in `build/qa-v3-cycle118-source-hashes.json`.

Focused verification passes **166 tests / seven suites**, zero failures/skips, in **11.970 seconds**
(`build/qa-v3-cycle118-focused-repaired.{log,xcresult}` and `-focused-summary.json`). Coverage
includes strict migration/injection, exact/reused/equal-clock identity refusal, expiry/cancellation,
cold/held history locking, non-replayable interruption, complete store → batch hook → executor
ordering, cancellation bridging, cleanup preservation and late-completion suppression.
The combined executor fixture uses real disposable source/WAV/relationship capture and synthetic
recognition; successful linkage is observed inside generation, and no transcript is saved.

The initial sandboxed Xcode attempt could not access package/compiler caches; authorized native
verification uses the normal approval mechanism. Integration diagnostics caught Swift Testing
throw inference and computed fixture actor isolation. Three parent test fixtures initially
violated queued→running completion and cold history setup; these were corrected without weakening
the contracts. The final focused run above passes those tests and all adjacent suites.

The first native run passes Caption consent/save/relaunch, both new cleanup workflows and normal
intent review/cancellation/relaunch, but finds the changed-relationship refusal message disappearing
before accessibility inspection. Successful two-second status polling had cleared the source-review
error without revalidating that source. The corrected model preserves the refusal until explicit
refresh. A deterministic changed-WAV model regression distinguishes successful status polling from
source revalidation. `build/qa-v3-cycle118-ui.{log,xcresult}` retains the initial native failure.

All five native workflows have passing evidence on the corrected final source:

| Native workflow | Passing duration |
| --- | ---: |
| Caption batch consent, editable draft refresh and relaunch | 36.768 s |
| Confirmed cancelled cleanup, Cancel preservation, retained intent and relaunch | 41.927 s |
| Changed store epoch refuses displayed confirmation and preserves evidence/relaunch | 40.548 s |
| Intent inspection, exact order, cancellation and relaunch | 34.088 s |
| Changed relationship refuses review, retains cancellation and survives relaunch | 32.145 s |

`build/qa-v3-cycle118-ui-final.{log,xcresult}` / `-ui-summary.json` retain the first four
passing workflows and an XCTest scrolling failure before the fifth workflow: Refresh had no
ScrollView hit point at line 188, before relationship mutation/inspection. With unchanged final
source, the isolated fifth workflow passes in `build/qa-v3-cycle118-ui-refusal.{log,xcresult}` /
`-ui-refusal-summary.json`, zero failures. This differs from the first run's product refusal-message
bug, which is fixed and passes deterministic and native regression checks. There is no claim of
a completely green five-test invocation; observed native passes are across the two final-source
runs. Existing native QoS/display diagnostics leave broader performance/display qualification open.
Cleanup changes no source/audio/relationship or operation evidence and saves no drafts; only the
explicit Caption fixture creates editable unapproved drafts through its isolated synthetic provider.

The built helper probe passes **30 tools**, persistent/pipelined protocol recovery, strict argument
refusal and honest unavailable execution boundaries, exit zero and zero stderr.
`build/qa-v3-cycle118-helper.{json,log}` records SHA-256
`6950cd53b481da98c6029575fcdc7738730720aacb55cf695b4291ed7fb1a8fa`.
Final repository validation passes in `build/qa-v3-cycle118-repository-complete.log`.

The complete serial integrated suite passes **3,704 tests / 364 suites**, zero failures/skips,
in **108.126 seconds** (`build/qa-v3-cycle118-full.{log,xcresult}` / `-full-summary.json`). Four
existing QoS diagnostics and 340 host `MDB_MAP_FULL` messages leave broader performance/environment
qualification open. Final helper bytes match the probe hash. Independent review finds no remaining
actionable source, evidence or scope issue. No new Release candidate or distribution artifact was built.
All **443 local Markdown links across eight changed documents** and final whitespace checks pass
(`build/qa-v3-cycle118-links.json`). Implementation commit `bfd8234` matches every verified source hash.

Reproduction uses the same project, derived-data location and serial macOS configuration. The
focused run adds `-only-testing:Aagedal Photo Agent Tests/<suite>` for
`AutomationVoiceTranscriptionBatchTests`, `AutomationTranscriptionReviewModelTests`,
`MCPVoiceTranscriptionReviewRequestStoreTests`, `MCPVoiceTranscriptionPlanStoreTests`,
`AutomationOperationRegistryTests`, `AutomationOperationExecutionCoordinatorTests` and
`MCPServerCoreTests`. Native runs substitute the `Aagedal Photo Agent UI Smoke Tests` scheme,
`-test-timeouts-enabled YES -default-test-execution-time-allowance 120
-maximum-test-execution-time-allowance 180` and `-only-testing:Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/<case>` for:

- `testNativeTranscriptionBatchConsentDraftRefreshAndRelaunch`
- `testNativeTranscriptionCancelledCapacityPreservesIntentAndRelaunches`
- `testNativeTranscriptionCancelledCapacityRefusesChangedConfirmationEpoch`
- `testNativeTranscriptionReviewInspectionCancellationAndRelaunch`
- `testNativeTranscriptionReviewRefusesChangedRelationshipAndRetainsCancellation`

The isolated refusal run selects only the last case. The full and static/protocol commands are:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/qa-v3-whisper-lifecycle-derived -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO -resultBundlePath build/qa-v3-cycle118-full.xcresult
scripts/ci/validate_repository.sh
python3 -B scripts/ci/probe_mcp_helper.py \
  'build/qa-v3-whisper-lifecycle-derived/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output build/qa-v3-cycle118-helper.json
git diff --check
```

## Next actions

1. Bind native provider/model/executable identity and requested options to exact rooted helper
   intent under whole-set source/metadata/relationship/WAV admission and authenticated IPC.
   Production provider consent/admission and guarded helper execution remain unavailable.
2. Qualify actual Apple/Whisper inference, cancellation/relaunch/offline/device behavior, signed
   model distribution/lifecycle and broader native recovery; connect remaining face/template
   workflow executors through the same guarded operation facade.
3. Preserve physical crash/archive-loss, cloud, authentic Sony/metadata/server/hardware,
   accessibility, display/HDR/solar, performance, privacy/legal, protected CI and exact signed
   candidate gates. Final user acceptance/publication stay separate; llama.cpp remains in 3.1.
