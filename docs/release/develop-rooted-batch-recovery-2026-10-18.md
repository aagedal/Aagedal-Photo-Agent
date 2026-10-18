# Develop rooted batch recovery — 2026-10-18

Continues the mutation-evidence prerequisite from clean baseline `09e2339`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

Batch checkpoints now own per-request rooted mutation journals under
`<batchID>/RootedMutations/<requestID>`. Obtaining a journal requires an existing
running checkpoint, its exact active request and no returned receipt. The first
attachment durably binds the original admission evidence, including the configuration
and ordered photo identities, with a separate checksum. Later attachments must match
those exact bytes. Existing version-one checkpoints remain readable; attaching rooted
evidence upgrades the checkpoint to version two so older writers refuse the new binding.
Subsequent checkpoint transitions preserve that evidence and version.

Every synchronous original/prepared/installed journal retention holds the parent
checkpoint lock while rechecking the current active request, original intent and exact
review binding. A stale handle cannot append after a terminal checkpoint. The parent
and child locks remain held through durable child retention. Obtaining this handle
neither manufactures consent nor validates current carrier authority; those checks
remain mandatory at the physical writer boundary.

Read-only recovery discovery includes bounded child journals while retaining the parent
lock. It refuses symbolic links, mismatched review material and unknown children;
unreadable child evidence leaves the valid parent and independently readable siblings
visible with an issue. The inventory's total recovery-byte limit includes the bound
admission evidence, original material and prepared candidates. Inspection creates no
locks, journals or repaired permissions and does not advance checkpoint sequence.

Recovery presentation distinguishes retained installation evidence from unresolved
preparation, where publication may have occurred. Journal evidence always requires
review and never creates a verified photo completion. The native view preserves
available photo evidence beside a child-journal issue instead of hiding the valid
batch. This is recovery plumbing; the existing admission executor is unchanged.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), development app 3.0.0/build 742.
Generated PNGs, templates and private journals live under `/private/tmp`; no user photo library is changed. Ignored pinned
AuraFace and web-runtime resources were copied from the main checkout for the bundled
build and are not source changes. The initial restricted Xcode attempt could not write
package/compiler caches; subsequent verification uses normal development cache and
signing access.

The focused run passes **46 tests in two suites**, zero failures/skips, in **1.935
seconds** of Swift Testing runtime. Parameterized executions include both current and
legacy publication, interrupted preparation, corrupt/orphan/symlink/missing-lock
children, exact binding refusal, checksum corruption and stale handles. Its result
summary reports zero runtime warnings. The integrated run passes **4,308 total tests
in 411 suites**: **4,306 passed**, zero failures and the two existing opt-in Sony
fixture skips, in **150.648 seconds** of Swift Testing runtime. Its summary also
reports zero runtime warnings. Existing `MDB_MAP_FULL` console observations remain;
this does not establish performance qualification.

Focused command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath /private/tmp/aagedal-batch-journal-focused-2.xcresult \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateRootedWriteServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchExecutionServiceTests' test
```

Focused console: `/private/tmp/aagedal-batch-journal-focused-2.log`.
Summary: `/private/tmp/aagedal-batch-journal-focused-summary.json`.
The integrated command uses the same settings without `-only-testing`, with result
bundle `/private/tmp/aagedal-batch-journal-integrated.xcresult` and matching `.log`.
Result-summary extraction required normal report-cache access.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-batch-journal-module-cache`:

```sh
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-batch-journal-repository-final.log`.
Swift frontend parsing and `git diff --check` pass. Independent review reports no
blocking findings within this checkpoint/recovery boundary. No native end-to-end
interaction, application-wide performance or distribution acceptance is claimed.

The persistent-pipe helper probe passes all **41 tools**. Bundled model validation
and final deep/strict development-signature verification pass after Xcode completes:

```sh
python3 -B scripts/ci/probe_mcp_helper.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output /private/tmp/aagedal-batch-journal-helper.json
python3 -B scripts/ci/validate_model_bundle.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
codesign --verify --deep --strict \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
```

Evidence: `/private/tmp/aagedal-batch-journal-helper.json`, matching `-helper.log`,
`-model.log`, `-signature-final.log` and `-integrated-summary.json`. Restricted
signature verification reported `CSSMERR_TP_NOT_TRUSTED`; normal trust-store access
passes. The final integrated build verifies the final production and test sources,
including all format-two validation changes.

## Remaining work

Connect one-way managed operation/owner linkage and the admission executor to this
checkpoint-owned rooted writer. Whole-batch authority must distinguish each current
owned carrier stage from untouched later photos. Connect native consent/Start and
exact terminal presentation only after that bridge preserves original request,
admission, operation and physical receipts through cancellation and recovery.

The next bridge must obtain its bound journal only after the running checkpoint is
durable, reconstruct the original snapshot under the retained reservation, and keep
the rooted writer's physical result even if terminal retention fails. Its synchronous
authority callback must expect original carriers before XMP, the exact owned XMP
snapshot before app metadata, and the exact owned app snapshot during verification,
while keeping later photos bound to their original witnesses. The current async,
original-only callback cannot safely be reused for that purpose. Bind the evidence
digest and batch once to the actual queued, uncancelled managed operation and owner
lease using registry-before-admission locking; duplicate Start, stale ownership,
revocation between carriers and uncertain retention require explicit regressions.

Embedded owned-effect stages and watermark dependency admission remain separate.
Native end-to-end interaction, real-volume performance, accessibility, Instruments,
provider/device and distribution qualification remain open. No release gate or audit
checklist count closes from this prerequisite.
