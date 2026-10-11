# Operation discovery and description queue recovery — 2026-10-11

Baseline `0846298`, initially clean. Implementation commits: `87dd2f9` (MCP discovery)
and `8d77952` (description queue/dictation fixes). Tests exercised these exact application
source changes before commit; source hashes are retained in the evidence directory.
State remains **IMPLEMENTING**. Two sub-agents
implemented the MCP discovery and atomic batch-description slices, then independently
cross-reviewed the changes and the coordinator's dictation cancellation fix.
No complete Phase 5A or release acceptance criterion closes.

## Behavior

- `list_operations` accepts no arguments and requires enabled local automation. It
  rechecks the exact authorization configuration around reading durable operation history.
  Up to 256 compact summaries are returned by descending creation time, with UUID tie
  ordering. This shared local history includes native and helper-linked operations;
  it is not filtered by client or folder. Owner identity, paths, transcript text,
  recovery receipts and individual batch progress are omitted. Recorded state is not
  proof of executor liveness, successful recovery or replay permission. Inspection
  does not start work, cancel work, clean history or alter records.
- Batch Description Assistant application stages an editor value locally and only
  publishes it after successful capture and FIFO admission. A removed-photo capture
  failure leaves the prior description and unrelated unsaved buffers unchanged;
  the same reviewed proposal can be retried. The existing queue remains responsible
  for later persistence failures and recovery. Queue admission is not verified disk
  persistence. Newer descriptions and uncommitted IME composition remain protected.
- Dictation language installation captures the requested locale and request identity.
  Cancelled or superseded completion cannot replace readiness or publish an obsolete
  error. Work ownership remains held until the suspended installation actually returns.
  This does not undo speech assets already installed by the operating system.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), Xcode 27.0. Debug app 3.0.0 build 741.
The ignored pinned AuraFace package was copied from the main checkout and passes
`build_auraface_coreml.py verify`. Existing local package checkouts were copied into
isolated derived data; automatic package resolution and updates were disabled.
No package pins or user automation/model preferences changed.

- Focused suite: **78 declared tests / three suites**, zero failures/skips; Xcode
  reports 126 expanded executions. New regressions cover operation discovery ordering,
  restart, privacy, strict arguments, full capacity and corrupt history; failed capture
  followed by retry and stale-description refusal; cancelled installation success/error,
  superseded language/readiness and current installation success.
- Integrated regression: **3,914 passed, two skipped, zero failed**, 3,916 reported
  tests across 389 Swift suites in 122.775 seconds. The two opt-in Sony skips provide
  no new authentic-camera evidence. Four existing QoS runtime warnings in
  CaptionSessionTests/MetadataEditorReadServiceTests and test-host LMDB map-full
  diagnostics remain observations; no performance gate closes.
- Repository validation passes, including generated metadata/component documents,
  release metadata, component provenance, privacy checks and model discovery.
- Actual bundled helper persistent-STDIO probe passes with 34 tools, strict discovery
  schema/argument refusal, pipelining, malformed-input recovery, clean exit and zero stderr.
  Helper SHA-256: `0ef02c39a9efcaaedf184b214dd6cb577b57581a696aea108a98a62a679d9900`.
  This probe does not enable automation or enumerate the user's operation history.
- Compiled AuraFace bundle validation and development signature verification pass.
- Independent cross-review found no blocking correctness issue. The pre-existing
  no-change suggestion path can acknowledge queuing without allocating another FIFO
  item; it does not mutate metadata. Dedicated native suggestion/dictation interaction
  was not performed in this cycle; deterministic regressions are automated evidence.

The first sandboxed Xcode invocation and repository model-discovery check could not
write normal compiler caches. Approved reruns succeeded. Sandboxed signature verification
could not resolve developer trust; the approved verification succeeds. The first helper
probe used an incorrect `Contents/Helpers` path; the actual bundled helper is in
`Contents/MacOS/photo-agent-mcp`. Exporting the full xcresult summary also required approved access to its report cache.
None of these failed preparation checks changed source.

Ignored evidence: `build/continuation-4/` contains `focused.xcresult`, `focused.log`,
`focused-summary.json`, `full.xcresult`, `full.log`, `full-summary.json`,
`repository-final.log`, `mcp-helper.json`, `signature-final.log` and source hashes.
App: `build/continuation-4/Build/Products/Debug/Aagedal Photo Agent.app`.
This Debug verification build is not the final notarized release candidate.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 \
  -derivedDataPath build/continuation-4 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-4/full.xcresult
scripts/ci/validate_repository.sh
python3 -B scripts/ci/probe_mcp_helper.py \
  'build/continuation-4/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp'
```

## Next production executor work

Develop-template application needs a reusable immutable Primary Develop request builder
extracted from `MetadataViewModel.commitPrimaryDevelopEdits`, retained exact template
inventory/source/XMP/history and decoder/as-shot evidence, explicit native plan review,
authenticated review transport, final whole-set revalidation and truthful operation
mapping from `PrimaryDevelopWriteResult`. Reuse `DevelopTemplate.settingsForApplication`,
`PrimaryDevelopWriteService`, `AutomationOperationExecutionCoordinator` and unselected
editor admission. Merely returning controls is not application authority.

Face scanning cannot safely wrap `FaceRecognitionViewModel.scanFolder` with an arbitrary
photo subset: the method assumes a complete folder inventory and prunes omitted faces
and signatures. Its private completion currently reports persistence errors rather than
an exact typed admission/terminal receipt. First extract a retained admitted scan handle,
authoritative complete-folder inventory and verified/failed/cancelled/uncertain outcome;
then connect exact native consent and MCP operation execution.

Signed Whisper production catalog/Settings integration, physical IPTC commit tools,
real-client/native/provider acceptance and broader hardware, interoperability,
accessibility, cloud/server, privacy/legal and candidate-release gates remain open.
