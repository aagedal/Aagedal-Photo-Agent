# Durable face anchored reset — 2026-10-17

Continues [anchored writes](durable-face-anchored-writes-2026-10-17.md) on clean
baseline `178116e`. State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

Retained full scans now reset through the same descriptor capability used for later
thumbnail/document publication. The complete `.face_data` tree is snapshotted before
any removal; traversal opens directories without following symbolic links and refuses
special files, invalid names, device crossings and replaced directory entries. Regular
file descriptors retain each snapshotted inode through removal. Nested files/directories
are removed in deterministic postorder with `unlinkat`; each successful removal is
recorded before synchronization, authority checks or other fallible verification.

Every removal rechecks the admitted root, storage, parent lineage and target identity.
Cancellation and authority withdrawal stop subsequent removals. Cancellation thrown by
the authority is retained even before task cancellation arrives. Parent-directory sync,
entry absence and full authority/identity checks qualify completion. A successful reset
clears the capability's removed directory bindings; later scan writes can recreate storage
without adopting an externally appearing replacement. Missing storage stays read-only.

The filesystem actor returns exact removed relative paths, completed status, cancellation
and any failure separately. Failed or partial reset stops before model detection or later
scan saves. Partial deletion remains in scanner completion, operation outcome and durable
receipt evidence, and requires recovery. Native completion presentation distinguishes
partial removal from a completed reset. Legacy receipts still decode; new exact evidence
validates path scope, uniqueness, final-root ordering and effect/result consistency.

An independent agent implemented receipt propagation and reviewed traversal/scanner changes.
Review found cancellation classification and misleading partial-reset presentation; both
are corrected. No unresolved correctness blocker remains from that review.

## Limits

This is not a crash-atomic multi-file reset. External same-user writers can race the narrow
identity-check/unlink system-call window; observable replacement refuses completion while
preserving the physical removal prefix. Symbolic links are refused before mutation; regular
hardlinks are unlinked only at their admitted storage entry without changing external bytes.
Snapshotting retains descriptors for all entries, so process descriptor limits can cause a
safe refusal before any removal. Traversal also bounds depth to 64 directory levels and
inventory to 100,000 child entries. Real-volume latency, peak memory and descriptor-capacity
qualification remain open.

Settings durable consent and Start remain disabled. This change enables the retained scanner
reset backend; it does not expose helper execution or alter request expiry/admission rules.

## Verification

Environment: macOS 27.0.1 (26A434), arm64; development app 3.0.0/build 742.
Tests use generated disposable files under `/private/tmp`; ignored pinned AuraFace and
web runtime resources were copied from the main checkout. The first restricted Xcode
attempt could not write package/compiler caches. The normal-access build initially
lacked the compiled model because its build graph predated resource provisioning; the
corrected run includes it. Evidence is in `build/face-anchored-reset/`.

The focused run passes **72 tests in three suites**, zero failures/skips, in 1.156
seconds of Swift Testing runtime. Its summary reports zero runtime warnings. Console:
`focused.log`; summary: `focused-summary.json`; result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_17-21-24-+0200.xcresult`.
The command is:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/FaceDataWriteCapabilityTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanAdmissionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPFaceScanOperationServiceTests' test
```

The integrated run rebuilds the final implementation and expanded test coverage with
the same command configuration and no `-only-testing` arguments. It passes **4,261 total
tests in 410 suites**: 4,259 passed, zero failures and the two existing opt-in Sony fixture
skips, in 139.799 seconds of Swift Testing runtime. The summary reports zero runtime
warnings. Console: `integrated.log`; summary: `integrated-summary.json`; result:
`/private/tmp/aagedal-settings-search-build/Logs/Test/Test-Aagedal Photo Agent Tests-2026.10.17_17-27-00-+0200.xcresult`.
Neither final console records Main Thread Checker or Thread Performance Checker messages.
Existing `MDB_MAP_FULL` console observations remain. The 10,000-file rename benchmark
reports 3.809 seconds and 53.5 MiB resident growth. These are regression results, not
real-volume performance qualification. The integrated run verifies the final implementation;
a later edit only clarifies its legacy/retained cancellation comment.

The expansion includes failures before/after every nested-tree removal, retained scanner
cancellation/error prefixes, hardlink byte preservation and depth-limit refusal. New receipt
coverage includes legacy decoding, full/partial/clean-cancellation roundtrips and eight
malformed evidence cases.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-reset-module-cache` (`repository.log`). The completed app
passes the actual persistent-pipe helper probe (`helper.json`, `helper.log`; all **41 tools**),
bundled model validation (`model.log`) and deep/strict development signature verification
with normal certificate access (`signature.log`). Final `git diff --check` passes. Source
and app hashes are in `source-sha256.json` and `artifact-sha256.json`. No native provider,
real-volume performance or distribution-signature qualification is claimed.

## Remaining work

Connect explicit native durable scan/reset consent and Start through the shared scanner and
operation service, and pass the original durable record/registry into completion validation
and history presentation. Preserve dismissal/cancellation drain, exact owner linkage and
original expiry. Actual provider interaction, real-volume performance, accessibility,
Instruments and distribution qualification remain separate release gates.
