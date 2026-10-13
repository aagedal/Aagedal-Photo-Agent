# Develop capture history inspection — 2026-10-13

Baseline: `9f8e6872`, initially clean. Implementation: `8afdc20`. This bounded
3.0 continuation adds durable capture discovery and native Settings presentation.
State remains **IMPLEMENTING**; no whole release or native acceptance gate closes.

## Implemented behavior

The admission store now defines a managed private `Automation/DevelopAdmissions`
location and projects validated historical journals into read-only presentation
records. The projection includes batch identity, template identity/name/revision,
ordered photo paths and source/XMP/app-metadata revisions. It excludes original
serialized writer requests, automation configuration and process-only review tokens.
Inspection uses the existing descriptor-anchored, no-follow, locked read-only
transaction. Missing storage returns empty without creating directories, journals
or locks. Corrupt, unsafe and inaccessible archives refuse inspection unchanged.

Settings → Automation → **Develop Capture History** offers managed inspection,
explicit original-folder selection and Refresh. Named expandable buttons expose
Expanded/Collapsed accessibility state. Awaiting review is historical status only;
consumed review does not prove consent or a physical write. The UI directs users to
separate Develop batch recovery checkpoints for physical outcomes. Relaunch cannot
reconstruct an executable capture or consent through this view.

Cancelled journals remain retained. They currently prevent the same capture identity
from being admitted again; deleting them to reclaim capacity would erase that
protection. Safe cleanup needs bounded durable tombstones and migration/replay tests
before evidence can be retired. No cleanup or execution action is added here.

UI-test managed discovery requires an explicit disposable admission root, matching
the existing checkpoint/face-receipt isolation policy. The feature guide and
limitations describe historical dispositions and the remaining cleanup boundary.

## Verification and environment

Host: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Tested Debug app: `build/continuation-15/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 742. This is a local development build, not a release candidate.
All six changed Swift-file hashes in `build/continuation-15/source-sha256.json`
match implementation `8afdc20`; source was stable throughout successful verification.
Core fixtures are generated disposable images, templates and journals.

Evidence retained under ignored `build/continuation-15/`:

- Focused tests: **26 passed / two Swift suites**, zero failures/skips, in
  **0.569 seconds** (`focused-v2.xcresult`, `focused-v2.log`, `focused-summary.json`).
  Historical inspection covers all three review states and original ordering,
  archive/directory/photo preservation, repeated reopening, corruption and symbolic
  link refusal. Managed storage tests cover absent storage, private permissions,
  symbolic ancestors and mandatory UI-test isolation.
- Full integrated regression: **4,078 passed, two opt-in Sony skips, zero failures**,
  out of 4,080 tests / 399 Swift suites, in **126.402 seconds**
  (`full.xcresult`, `full.log`, `full-summary.json`). Four existing summary QoS
  warnings and test-host `MDB_MAP_FULL` logging retain performance/environment gates.
- Repository validation passes (`repository.log`); final `git diff --check` passes.
- Bundled model verification passes (`model-bundle.log`). Strict deep development
  signature verification passes (`signature.log`); this is not notarization.
- Actual persistent STDIO helper probe passes **36 tools**, malformed/strict argument
  refusal, exit zero and zero stderr (`helper-final.json`, `helper-final.log`).
  The first helper probe used an incorrect guessed path and did not execute;
  the corrected probe uses `Contents/MacOS/photo-agent-mcp`.

The initial restricted build could not write normal compiler/package caches
(`focused.log`); approved cache access resolved that. The first approved build
compiled application source but stopped in packaging because the fresh worktree
lacked the ignored web-downloader runtime (`focused-approved.log`). The pinned
AuraFace package and cached dependencies were copied locally; the prepared runtime
was copied from the earlier web-import worktree and passed the build's manifest
verification. The successful focused rerun is authoritative. No neighboring
checkout or source resource was modified.

Native acceptance remains **unverified**. Both the three-workflow native run and the
isolated new-workflow retry failed before tests or application launch with:

> The test runner failed to initialize for UI testing. (Underlying Error: Timed out while enabling automation mode.)

Evidence: `native.xcresult`/`native.log` and `native-v2.xcresult`/`native-v2.log`.
The selected tests cover missing/corrupt storage, consumed-review detail,
refresh, unchanged photo/journal bytes and relaunch, plus adjacent Develop recovery
and face-receipt workflows. Compiling these tests does not satisfy their UI criteria.

The native computer-use fallback opened the exact built app and initially observed
an empty browser. Before the Settings action, the tool reported that the app had
changed; refreshed state showed active photo/export work. Interaction stopped to
avoid interrupting that work. No capture-history UI case passed through this
fallback, and the active app was left untouched. An unused disposable three-state
journal remains in `cua-fixture/` for later inspection. No production photo write,
review approval, automation setting change or journal cleanup was requested by this
continuation. The implementation diff was self-reviewed; independent release audit
remains a separate outstanding gate.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-15 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-15/full.xcresult
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent UI Smoke Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-15 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testDevelopCaptureInspectionPreservesHistoryAndPhotos' \
  -resultBundlePath build/continuation-15/native-v2.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-15/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
```

## Next actions

1. Re-run native capture-history and adjacent recovery cases when desktop automation
   can initialize and the app is available for isolated testing.
2. Add replay-preserving tombstones before cancelled-capture capacity cleanup; retain
   consumed/uncertain records until separately confirmed physical outcomes qualify.
3. Connect exact Develop capture review to native execution and managed storage;
   retain embedded owned-effect stages, synchronous rooted commit and watermark
   authority requirements. Continue authenticated face execution/anchored effects,
   signed Whisper provisioning and the broader release qualification gates.
