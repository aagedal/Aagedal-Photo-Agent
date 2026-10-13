# Durable face operations and independent Develop capture — 2026-10-13

Baseline: `3c748b8`, initially clean. Two implementation sub-agents and an
independent reviewer continued the 3.0 handoff; the coordinator integrated scanner
authority, managed recovery access, project membership and verification. State
remains **IMPLEMENTING**. No complete release gate closes.
Implementation: `813d2b4`. Native test activation/synchronization correction:
`7e46d15`; it changes only the recovery UI test, not application or core-test source.

## Implemented behavior

The app-side face operation bridge durably retains an exact session intent's
identity, inventory revision, options and operation link before scheduling. A
bounded private receipt archive uses the existing anchored, no-follow, locked,
fsynced persistence primitive. Intents are single use; restarting or reconciling
abandoned owner leases never replays scans.

Every returned task is retained and drained before terminal coordination,
including mismatched submissions. Completion retains exact committed thumbnail
UUIDs, document and reset dispositions, deletion receipts, post-commit cancellation
and authority-refusal flags. A mismatch or failed history read preserves physical
evidence as recovery required. Uncertain effects cannot become clean cancellation.
Native admission requires a caller-supplied exact-intent capability validator,
forwarded to scanner admission and retained read/effect boundaries. This creates
no native consent grant or helper endpoint.

Cancellation targets the exact retained submission rather than the scanner's
current slot. The operation's 100 ms watcher also observes direct durable registry
requests and fails closed on unreadable history. It is cancelled and joined after
the scan finishes. Shutdown drains work even when cancellation persistence fails.

Independent app-side Develop capture retains the exact template descriptor and
ordered rooted photo/carrier reads while resolving target-specific decoder facts
and building immutable writer requests. Source hashes, carrier revisions, root
identities and decoder evidence come from current retained bytes. Template layers
receive fresh identities per photo, while destination crops and pending editorial
draft/history are preserved. Template/carrier drift, conflicts, pending orientation,
history-only mode, duplicate/excessive selections, unsupported watermark dependencies
and size excess refuse admission. Capture neither writes nor approves execution.

Develop recovery now has one managed Application Support location shared by
future execution and current Settings inspection. **Review Managed Develop
Recovery** and Refresh report an empty location before the first checkpoint without
creating folders, locks or journals. Explicit folder selection remains available.
No-follow and private-permission checks still refuse unsafe existing roots. UI tests
require an explicit disposable checkpoint location.

## Review and boundaries

Independent review corrected premature finalization of mismatched scheduled tasks,
lost physical receipts after coordination errors, and shutdown returning before
worker drain. Native capability validation now reaches scanner boundaries; durable
cancellation reaches the exact task. Unknown nested receipt fields and malformed
phase/identity records refuse even with recomputed checksums.

Authenticated native face review/consent, production bridge construction and receipt
presentation remain to be wired. The physical face scanner still publishes through
path-based storage; descriptor-anchored authorized-root mutation remains open.
`start_face_scan` is not exposed by the helper. Develop capture currently uses the
enabled authorized read facade/template discovery internally. Native exact-capture
review, durable capture retention, production execution wiring, watermark dependency
admission and anchored publication remain open. The managed recovery action inspects
checkpoints only; it does not validate current photo bytes or grant replay.

Signed Whisper provisioning, authentic-media/interoperability, hardware, broader
accessibility/performance and signed-release qualification remain open.

## Verification

Evidence is retained under ignored `build/continuation-13/`. Host: arm64 macOS
27.0.1 (26A434), Xcode 27.0 (27A266a). The pinned ignored AuraFace package and cached
dependency checkouts were copied into this worktree. Fixtures are generated disposable
images and synthetic face records; recognition quality is not claimed. The tested
Debug app is `build/continuation-13/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 742. This is a local continuation candidate, not a published beta.

Final evidence:

- Focused verification passes **92 tests / six Swift suites**, zero failures/skips,
  in **1.273 seconds** (`focused-v4.xcresult`, `focused-summary.json`,
  `focused-v4.log`). It includes actual Develop capture → writer → reopened checkpoint
  and face intent → native scanner → saved document → durable receipt integration.
- Committed implementation `813d2b4` passes **4,050 tests, two opt-in Sony skips,
  zero failures** out of 4,052 tests / 396 Swift suites in **124.984 seconds**
  (`full.xcresult`, `full-summary.json`, `full.log`). Four existing summary QoS
  warnings and test-host `MDB_MAP_FULL` logs retain performance/environment gates.
- The three existing native face workflows pass on that application source:
  complete two-image scan/relaunch (**24.114 seconds**), explicit jersey-scan
  cancellation (**21.609 seconds**) and historical missing-thumbnail repair/relaunch
  (**21.932 seconds**), recorded in `native.xcresult`/`native.log`. That bundle also
  retains the first unsuccessful recovery attempt; it is not a four-test passing bundle.
- Final recovery UI source `7e46d15` passes managed absent-folder inspection/Refresh,
  explicit unreadable evidence selection, accessible name/status, Refresh and exact
  photo/evidence/directory preservation in **38.547 seconds**, zero failures/skips
  (`native-recovery-v3.xcresult`, `native-recovery-summary.json`,
  `native-recovery-v3.log`). All four workflows therefore have passing evidence;
  the recovery UI test correction leaves the other methods and production source unchanged.
  Native main-thread/QoS and desktop interruption observations retain broader UI and
  performance qualification.
- Repository validation passes (`repository-final.log`). The post-native model bundle
  check and development signature verification pass (`model-bundle-post-native.log`,
  `signature-post-native.log`). The actual persistent STDIO helper passes with **36 tools**,
  strict argument refusal, exit zero and zero stderr (`mcp-helper-final.json`,
  `mcp-helper-final.log`). No face execution endpoint was added.
- All **14** final changed source/test/project hashes match `7e46d15`
  (`source-sha256.json`). The initial manifest remains in
  `source-sha256-implementation.json`; its sole later change is the recovery UI test.
  Post-native process inspection finds no Photo Agent instance left running
  (`process-post-native.log`). No unrelated application was closed or modified.
- Independent implementation, authority/receipt review and final test-contract review
  pass. XMP owns Develop settings; JSON deliberately excludes Camera Raw/orientation.
  Integration checks serialized editorial snapshots/history alongside XMP controls,
  geometry and layer order. Parser-generated mask UUIDs are not persisted app identities.

The initial restricted build could not write normal compiler/package
caches; approved Xcode execution resolved that. An initial focused selection ran only
the existing suites because the test target has an explicit file list. All three new
test files now have build-file, file-reference, group and Sources membership. Initial
new-test compilation exposed missing inner `try` expressions in Testing macros and
two decoder argument labels; these were corrected without weakening assertions.
The first all-suite focused attempt exposed incorrect fixture assumptions about canonical
paths, JSON Develop serialization, runtime mask UUIDs and absent read-only registry locks;
corrected tests retain meaningful control/geometry/history/drift and no-enqueue assertions.

The initial native recovery attempt inspected the old empty-folder status while its
chooser remained open; the next attempt could not find a scroll hit point amid overlapping
Media Converter windows. Explicit test-app activation, keyboard panel completion and
waiting for the exact new entry resolve the final workflow. Separate desktop inspection
failed with `Sky Computer Use native pipe closed before response`; the final runner result
above is authoritative. Restricted signature inspection reported trust-service refusal;
approved read-only verification passes. No automatic approval-review rejection blocked work.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-13 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-13/full.xcresult
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-13 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testDevelopRecoveryInspectionPreservesUnreadableEvidence' \
  -resultBundlePath build/continuation-13/native-recovery-v3.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-13/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

## Next actions

1. Wire authenticated native exact-intent face consent and production operation/receipt
   presentation/live progress, then anchor physical face effects.
2. Retain/review exact Develop captures durably, connect native execution to the managed
   checkpoint root, and admit watermark dependencies with anchored publication.
3. Finish production signed Whisper provisioning and the broader release qualification.
