# Historical face thumbnails and durable Develop checkpoints — 2026-10-12

Baseline: `d029fc2`, initially clean. This continuation implements the next bounded
face-completeness and Develop-recovery work from the previous
[handoff](retained-face-authority-develop-batch-2026-10-12.md). State remains
**IMPLEMENTING**; no complete release gate closes.
Implementation commits: `02b9124` (XMP/JSON authority), `56c8347` (batch checkpoint
storage) and `577194d` (historical face thumbnails).

## Behavior

Loaded face-scan completion now requires a readable thumbnail for every retained face.
Missing crops change in-memory presentation without rewriting the historical document.
An explicitly requested incremental scan recreates missing thumbnails from the stored
rectangle only when the original source signature is unchanged. It preserves face IDs,
embeddings, manually named groups and jersey results. Failed/cancelled repairs remain
incomplete and retryable. Source drift removes the old signature so the next scan must
detect the changed image again. This checks missing/read-failed thumbnails; it does not
validate the visual correctness of every existing thumbnail.

Develop batches have a concrete durable checkpoint adapter. Each batch has a private
journal using the existing descriptor-anchored persistence service: protected permissions,
cross-instance/process locking, bounded regular-file reads, atomic replacement and file/
directory/ancestor flushes. Versioned checksummed checkpoints retain the original ordered
requests, template identity, exact physical receipts, completion flags and unresolved
active request. Changed intents/receipts, backwards state transitions, erasure of unresolved
work and corrupt/newer checkpoints refuse replacement. Restart discovery exposes review
evidence without granting replay permission. Checksums detect corruption, not malicious
changes by the same local account.

The executor rechecks the whole carrier set after the awaited initial running checkpoint,
before its first physical writer. A mismatched writer receipt retains its actual reported
request ID and physical evidence separately from valid completion receipts. Batch intent
admission defensively rejects repeated request UUIDs as well as shared carrier identities.

Primary Develop callers can supply a synchronous authority check inside XMP publication
after its intentional yield, immediately before JSON saving after awaited source checks,
and after JSON commit before verified completion. Refusal retains committed XMP or
committed-but-unverified JSON evidence. The batch engine initializer forwards this capability;
existing native callers retain their default behavior.

## Review and limits

Two implementation agents owned independent face and checkpoint slices, with a third
agent reviewing them. Integration review corrected stale-whole-set admission, mismatched
receipt loss, dynamic evidence in immutable intent comparison, cancellation classification,
loaded completion presentation and unresolved-checkpoint rollback.

Production template capture, authenticated native consent, storage-root selection,
recovery UI and rooted automation execution remain required. Durable evidence is not
an executable request reconstruction or a retry grant. Embedded writing still uses its
existing asynchronous admission callback; exact synchronous authority inside the embedded
physical engine remains open. Path-based XMP/JSON publication is not descriptor-anchored
mutation of an authorized photo root. No new helper execution tool is advertised.

## Verification

Evidence directory: ignored `build/continuation-11/`. Host: arm64, macOS 27.0.1
(26A434), Xcode 27.0 (27A266a). The pinned ignored AuraFace package and cached package
checkouts were copied locally into this fresh worktree. All fixtures are disposable
generated images and synthetic face records; recognition accuracy is not claimed.
All 13 source-file hashes in `source-sha256.json` match committed `577194d`.
Only documentation changed after those source commits. Tested app:
`build/continuation-11/Build/Products/Debug/Aagedal Photo Agent.app`, version 3.0.0,
build 742, development signed. This is a local continuation build, not a published
beta or final Release candidate.

Final focused verification passes **71 tests / three Swift suites**, zero failures or
skips, in **0.927 seconds** (`focused-final.xcresult`, `focused-summary.json`,
`focused-final.log`). It covers crop reconstruction, missing-thumbnail loaded presentation,
repair failure/cancellation/source drift and identity-preserving retry; actual XMP/JSON
commit refusal with physical receipts; checkpoint restart, corruption/newer schema,
changed intents/receipts, rollback, symlink refusal and mismatched receipt retention.

Final repository and whitespace checks pass (`repository-final.log`). The actual
embedded persistent STDIO helper probe passes with **36 tools**, strict argument
refusal and zero stderr (`mcp-helper.json`, `mcp-helper.log`). Bundled AuraFace payload
and development signature validation pass (`model-bundle-final.log`, `signature-final.log`).
The final integrated suite passes **4,001 tests, two opt-in Sony skips, zero failures**
out of 4,003 tests / 393 Swift suites, in **124.752 seconds** (`full.xcresult`,
`full-summary.json`, `full.log`). Four recorded Caption/metadata-read QoS warnings
retain performance qualification; test-host `MDB_MAP_FULL` logging remains an observation.

All **three native workflows pass**, zero failures/skips (`native-face.xcresult`,
`native-face-summary.json`, `native-face.log`): complete two-image scan and byte-identical
document across relaunch (23.855 seconds); cancellation of the explicit jersey-rescan
confirmation without creating face data (12.770 seconds); and a historical synthetic
face with a missing crop, repaired through the native incremental scan and retained
across relaunch (21.319 seconds). The last case verifies original face/group IDs,
group name, stored embedding bytes and jersey value, as well as a decodable recreated
JPEG and identical thumbnail bytes after relaunch. Fixtures use a disposable Known
People root and process-only preferences. Four native QoS/main-thread warnings retain
performance qualification. This qualifies repair/persistence, not recognition accuracy,
thumbnail-failure UI or Develop consent/recovery UI. Post-native development signature
verification passes (`signature-post-native.log`). Desktop inventory confirms no
Photo Agent instance before the cycle and none left running afterward; the read-only
observation call returned after the tests and showed an empty app window, which was
closed. That observation is not separate repair interaction evidence.

The first restricted Xcode attempt could not write external compiler/package caches;
approved Xcode access completed compilation. One new test assertion needed its awaited
counter read extracted before Swift macro evaluation. The first focused run then exposed
two fixture assertion mistakes: 120-point AppKit crops encode 240 pixels on this Retina
host, and JSON deliberately stores an editorial projection rather than CRS. Corrected
tests retain usable-square-crop, actual XMP-settings, editorial JSON, exact refusal and
physical recovery assertions. Independent review accepted these corrections; no
production assertion or acceptance requirement was relaxed.
No automatic approval review rejection blocked validation.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath build/continuation-11 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-11/full.xcresult
CLANG_MODULE_CACHE_PATH="$PWD/build/continuation-11/RepositoryModuleCache" \
  scripts/ci/validate_repository.sh
git diff --check
```

Focused selection: `ActivityHistoryTests`, `DevelopTemplateBatchExecutionServiceTests`
and `PrimaryDevelopWriteServiceTests`. Native selection uses `Aagedal Photo Agent UI
Smoke Tests` and `CoreWorkflowSmokeTests/testCompleteFolderFaceScanPersistsAcrossRelaunch`,
`testHistoricalMissingFaceThumbnailRepairPersistsAcrossRelaunch` and
`testExplicitJerseyScanCancellation`.

## Next actions

Connect retained face intents to authenticated native consent and durable operations,
with rooted authority throughout scanner effects. Connect Develop template capture,
native review, checkpoint recovery presentation and anchored physical authority,
including embedded publication. Continue production signed Whisper catalog/key and
Settings integration, then broader native, authentic-media, device, accessibility,
performance and signed-candidate qualification.
