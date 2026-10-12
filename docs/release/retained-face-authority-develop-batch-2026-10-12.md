# Retained face authority, thumbnail persistence and Develop batches — 2026-10-12

Baseline: `403608a`, initially clean. This development continuation does not replace
published Beta 3 or close a whole release gate. State remains **IMPLEMENTING**.
Implementation commits: `e187747` (face authority/intents), `036ef5d` (thumbnail
persistence) and `5ee9dc4` (Develop batch core).

## Behavior

Rooted face preparation now supports an explicitly retained descriptor and exclusive
folder reservation that survives asynchronous suspension. Frozen authorization and
the complete immediate image inventory are checked at admission and before/after
synchronous boundaries. Release is serialized and idempotent. A bounded session store
retains immutable normalized intents for five minutes, with at most 16 entries and
20,000 total image witnesses. Expiry, backward/invalid clocks, changed inventories,
revocation and busy folders refuse admission. These APIs grant no native consent,
create no durable operation and expose no new helper execution tool.

Native scanning retains faces only after their thumbnails commit. Failed or cancelled
thumbnail writes leave the image unsigned and the scan incomplete, permitting retry.
Mixed-result retries remove discarded face IDs from groups. Thumbnail writes are
atomic. Typed completion separates attempted thumbnail failures/cancellation; UI errors
and persisted Activity history retain save failures, including final-document failures.
Legacy Activity records without the optional persistence field still decode.

The new app-side Develop batch core accepts up to eight independently captured Primary
Develop requests. It holds every shared photo reservation through final checkpointing,
checks the entire source/XMP/JSON set before the first write, and retains original ordered
requests and exact physical receipts before/after effects. A failed checkpoint or stale
later destination prevents initial writes. Partial writes, cancellation after completion,
unexpected receipt identity and failed terminal retention retain explicit recovery state.
Authority is rechecked after awaited checkpoints and at the existing writer's supported
async admission boundaries. Watermark-bearing batches refuse until dependency admission
is wired. Existing native Primary writes continue to acquire their own reservation;
batch callers can supply a checked retained lease.

## Review and limits

Three implementation agents owned separate slices; each slice received independent
cross-review. Review found authority could change during an awaited prewrite checkpoint;
the corrected writer rechecks authority afterward, with a zero-write regression case.
The coordinator added explicit Xcode test-target membership for the new batch suite.

The face descriptor callback is an internal primitive, not an atomic external-edit
snapshot: directory names are enumerated through the canonical path, while per-image
inspection is descriptor-relative. Its callback must neither close nor escape the
descriptor. A post-boundary refusal may follow an already committed effect; a future
executor must retain that effect's receipt separately. Historical unchanged face
documents with already missing thumbnails are not retrospectively qualified.

Develop caller-supplied authority validation and durable retention are capabilities,
not shipping storage/consent integration. Async authority checks do not occur inside
every separate XMP/JSON commit boundary. Rooted anchored mutation authority, durable
operation/replay handling, native approval, template/decoder preparation and watermark
dependencies remain required before advertising production automation execution.

## Verification

Evidence: ignored `build/continuation-10/`. Host: arm64, macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a). Cached pinned dependencies and the existing ignored AuraFace
package were copied locally. Tests use disposable synthetic image/model inputs;
no user photo or production service authority changed. The exact 12 modified/new
source/project files are recorded in `source-sha256.json`.

All 12 source/project hashes match committed `5ee9dc4`; only documentation remained
dirty after implementation commits. Tested app: `build/continuation-10/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 742, development signed. This is not a published beta or final
Release candidate.

- Focused: **77 tests / four Swift suites**, zero failures/skips, 0.836 seconds
  (`focused.xcresult`, `focused-summary.json`, `focused.log`). Includes actual production
  XMP writes and physical partial-write receipts, checkpoint revocation/failure,
  reservation lifetime, cancellation, retained face inventory/clock drift,
  thumbnail failure/mixed retry/cancellation and Activity legacy decoding.
- Integrated: **3,990 passed, two opt-in Sony skips, zero failures** out of 3,992
  tests / 393 Swift suites, 129.887 seconds (`full.xcresult`, `full-summary.json`,
  `full.log`). Four Caption/metadata-read QoS warnings retain performance qualification;
  test-host `MDB_MAP_FULL` logs remain an observation.
- Native: **two workflows passed**, zero failures/skips (`native-face.xcresult`,
  `native-face-summary.json`, `native-face.log`). A complete scan of two generated JPEGs
  persists completion and byte-identical face data across relaunch (23.731 seconds).
  Cancelling the explicit jersey-rescan confirmation creates no face-data directory
  (12.879 seconds). Fixtures use a disposable empty Known People root and process-only
  browser preferences. This qualifies zero-face scan/persistence/cancellation, not
  recognition accuracy, thumbnail-failure UI or Develop batch consent UI. Two native
  main-thread warnings retain performance qualification. Desktop inventory before/after
  testing confirms no unrelated Photo Agent instance and no test app left running.
- Repository/whitespace checks, final bundled model and post-native development
  signature verification pass (`repository-final.log`, `model-bundle-final.log`,
  `signature-post-native.log`).
- Actual embedded persistent STDIO helper: **36 tools**, strict malformed/execution
  argument refusals, zero stderr (`mcp-helper-final.json`). `start_face_scan` remains
  absent; read-only preparation still grants no mutation permission.
- Independent cross-review passes within the documented bounded foundation scope.
  No full production executor or release acceptance criterion is checked by this work.

The initial restricted Xcode build could not write external compiler/package caches.
Approved system cache access completed builds and tests. Result summary extraction
also required approved xcresulttool report-cache access. No automatic approval review
rejection blocked validation. No implementation test failed or assertion was weakened.

Commands (all Xcode runs share `build/continuation-10`):

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-10 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-10/full.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-10/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

Focused testing adds selectors `ActivityHistoryTests`, `MCPFaceScanAdmissionServiceTests`,
`DevelopTemplateBatchExecutionServiceTests` and `PrimaryDevelopWriteServiceTests`;
native testing switches to `Aagedal Photo Agent UI Smoke Tests` with selectors
`CoreWorkflowSmokeTests/testCompleteFolderFaceScanPersistsAcrossRelaunch` and
`CoreWorkflowSmokeTests/testExplicitJerseyScanCancellation`.

## Next actions

Connect retained face intents to authenticated native consent and durable operations,
with rooted authority through scanner postprocessing and every write. Add historical
thumbnail completeness evidence. Wire Develop batch capture/consent/storage and anchored
authority at every physical boundary, then template batches and recovery presentation.
Continue signed Whisper production catalog/key provisioning, shipping Settings wiring
and broader native, accessibility, performance, authentic-media/cloud/device qualification.
