# Cycle 88 — native pending-draft execution and repeatable Whisper probes

Baseline: `e64e47f`, initially clean. Status remains **IMPLEMENTING**.
Implementation commits: `fb61dab` (Whisper qualification) and `b00cfd1` (native pending-draft execution).
The focused/full/native runs exercised these combined application sources before committing;
only release evidence and planning status changed afterward.
No broad release gate is closed by this cycle.

## Implemented behavior

Settings → Automation now connects **Approve Reviewed Plan** to a separate, explicit
**Apply to Pending Draft** action. Approval alone still writes nothing. Application consumes
that exact session receipt and saves app-owned pending metadata history, without publishing
embedded or XMP metadata. Direct MCP `commit_iptc_patch` remains unavailable.

The executor holds the shared process reservation and metadata I/O lock, rechecks the immutable
plan, authority and carrier revisions, and refuses photos selected in any native metadata editor.
Selection registration is synchronous; it does not call MainActor from a filesystem transaction.
The production JSON codec first runs in private staging. Opaque nested extensions that it cannot
preserve cause refusal before installation. Existing original snapshots, private records and
bounded history remain under the production persistence policy.

Installation walks the authorized directory chain without following links and writes, syncs,
renames and cleans up relative to retained descriptors. The sole legacy carrier is updated in
place, avoiding a second untracked migration. Verification requires the exact staged JSON,
all effective descriptive fields, original source/XMP bytes and revisions, and current authority.
The executor never guesses a recovery file URL when installation did not return one.

The retained operation coordinator uses the distinct `iptc_draft` kind. It records admission and
execution, checks durable cancellation before effects, and verifies an already installed draft
rather than reporting a false no-effects cancellation. Unexpected failure after possible effects
requires recovery. Closing the Settings review requests cancellation but does not abandon the
retained operation. Results distinguish verified draft, refusal, cancellation and recovery.

The Whisper process probe now runs model-free in repository validation: required filter options,
generated PCM input decoding, and controlled missing/malformed model failure. An optional local
model/audio run additionally checks CPU silence/speech, canonical JSON, timestamp bounds and
output-destination failure. It downloads nothing and explicitly makes no accuracy/GPU claim.

## Verification

Environment: arm64 macOS 27.0 (26A428), Xcode 27.0 (27A266a), Debug app 3.0.0 (739).
App path: `~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Fixtures are generated local JPEG/PCM files and isolated authorization/plan/operation storage;
no user photo or automation authorization is changed by the tests.

- Focused application checks: **33 tests / four suites pass**, zero issues, 1.103 seconds.
  `build/qa-v3-cycle88-focused-final.{log,xcresult}` covers executor, operation lifecycle,
  selected-editor admission and native review-model integration.
- Complete integrated regression: **3,265 tests / 341 suites pass**, zero failures,
  120.405 seconds. Evidence: `build/qa-v3-cycle88-full.{log,xcresult}`.
- Native UI: **three tests pass**, zero failures, 90.599 seconds. Evidence:
  `build/qa-v3-cycle88-native.{log,xcresult}`. The new workflow checks explicit approval and
  application, verified draft status, unchanged photo/XMP bytes, exact title/clear values and
  persistence after relaunch. Existing revocation/source-drift and invalid-plan refusal cases pass.
- Repository validation passes: `build/qa-v3-cycle88-repository-final.log`.
- Actual embedded helper persistent-pipe probe passes all 15 advertised tools:
  `build/qa-v3-cycle88-mcp-probe.{log,json}`. No mutation endpoint was introduced.
- Whisper validator: eight regression tests and seven real-process checks pass, including
  CPU inference on the existing local model and synthetic speech. Evidence:
  `build/qa-v3-whisper-repeatable-final/report.json`. Speech spans 5,048 ms and silence 5,000 ms;
  both outputs contain two bounded segments. Missing/malformed models exit 251 and an invalid
  destination exits 235. These results do not establish recognition accuracy.

Commands use the repository Xcode test schemes, Debug, `-destination platform=macOS`,
`-parallel-testing-enabled NO -jobs 3`, and the named result bundles. Focused selectors are
`AutomationPatchReviewTests`, `MCPIPTCPatchExecutionServiceTests`,
`AutomationOperationExecutionCoordinatorTests` and `AutomationDraftEditorAdmissionTests`.
Native selectors in `CoreWorkflowSmokeTests` are `testAutomationPatchAppliesOnlyToPendingDraft`,
`testAutomationPatchApprovalRevokesAndRefusesChangedPhoto` and
`testAutomationPatchReviewRefusesInvalidPlanWithoutChangingPhotos`.
Repository validation runs `scripts/ci/validate_repository.sh`; the helper probe runs
`python3 -B scripts/ci/probe_mcp_helper.py <built-helper> --output <evidence-json>`.

Initial verification exposed a recursive nested test macro and noncanonical `/var` fixture paths
rejected by the existing descriptor-based operation archive. Fixtures were corrected with POSIX
`realpath`; production path protections and failure assertions were not weakened. Independent
review identified path-based installation and nested-extension-loss risks before shipping; both
were replaced with the rooted/staged behavior described above and covered by adversarial tests.
CUA observed the rebuilt app's Browser/empty-selection state; workflow assertions use native XCTest.

## Remaining release work

- Explicit physical write-mode consent, publication/C2PA policy, carrier preservation/read-back,
  recoverable physical installation and `commit_iptc_patch` remain mandatory.
- Other MCP face, metadata/Develop-template and transcription executors remain unfinished.
- The coordinator can drain and reconcile a known stopped owner, but automatic crash/relaunch
  liveness, recovery execution/UI and terminal-record management are not integrated. The operation
  archive remains bounded; verified draft status is not proof of physical publication.
- Selected photos are conservatively refused even when the editor appears clean. Native coverage
  still needs broader multi-window conflict, cancellation and recovery cases. Coordination covers
  cooperating app/helper processes; noncooperating same-user replacement at the final install
  boundary can cause uncertain results. No general hostile-process or power-loss guarantee is made.
- Whisper corresponding-source publication/clean reproduction, signed model update/rollback,
  offline/GPU/audio-format and recognition-quality acceptance remain open.
- Authentic Sony/real-server/cloud evidence, external interoperability, accessibility, display/HDR,
  performance/hardware, qualified privacy/legal review, remote CI protection, a final signed and
  notarized candidate, and user acceptance remain release gates.
