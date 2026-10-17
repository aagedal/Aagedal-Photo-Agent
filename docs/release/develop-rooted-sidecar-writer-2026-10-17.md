# Develop rooted sidecar writer — 2026-10-17

Continues the Develop review plan from clean baseline `087efa8`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

`DevelopTemplateRootedWriteService` is an app-internal physical prerequisite for
reviewed Develop batches. It accepts only independently captured sidecar-only requests
and an exact rooted source/XMP/app snapshot under the caller's retained photo reservation.
It refuses embedded policies, predecessors, missing or changed capture evidence,
watermark dependencies, pending orientation and inconsistent intended metadata.
It is deliberately not connected to native Start or the existing batch executor.

Candidates are built through the production XMP and app-sidecar codecs in a private
staging directory using captured source bytes for crop-aspect calculation. The writer
checks editorial values, orientation policy, parseability and private JSON preservation.
Technical Develop values use the existing structured codec; raw settings equality is
inappropriate because parsing supplies defaults and new mask UUIDs. Regression tests
check actual exposure, crop, mask properties and order alongside editorial history.

The original source and both carrier generations are validated before staging and
publication. Both physical installs use the existing descriptor-relative facade
primitives. There is no suspension between final staged preparation, carrier installs
and completion checks. The authority callback receives the original snapshot before
XMP, the exact installed XMP snapshot before JSON, and the installed app snapshot for
verification. This allows future batch admission to validate untouched later photos
without rejecting the writer's own earlier carrier. Caller cancellation crosses the
metadata coordinator's retained task boundary and prevents subsequent effects.

Authority validation and prepared-mutation retention are mandatory synchronous
callbacks. The latter receives the physical stage, staged device/inode/size/mtime and
exact candidate bytes, and must retain durable recovery evidence before returning.
These callbacks do not manufacture consent or operation linkage. The caller remains
responsible for the original request, whole-batch authority and managed lifecycle.

Failure returns exact installed snapshots where available and conservative possible-write
evidence after the rename boundary. Final failure never claims a verified app record.
The rooted app installer reports its selected destination, so a sole legacy JSON
filename remains correctly identified in uncertain-write receipts.

Independent review found an inherited facade gap: staged identity and bytes had been
checked before the durable callback but not after it. Both XMP and app installers now
recheck the retained descriptor and temporary entry, exact prepared identity, regular
single-link ownership and full bytes immediately before rename. Deterministic tests
replace the temporary inode with identical bytes or edit its content during the
retention callback and require refusal without publishing that carrier.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), development app 3.0.0/build 742.
Fixtures are disposable generated PNGs, templates and private journals under
`/private/tmp`. One agent implemented the writer and an independent agent reviewed the
service and shared installer changes. The staged-generation finding above is resolved;
no review objections remain within this boundary.

The focused run passes **95 tests in four suites**, zero failures/skips, in **10.242
seconds** of Swift Testing runtime. Its result summary reports zero runtime warnings.
This includes the new writer's 14 tests (21 executions including parameterized cases), existing
Develop capture/execution and rooted IPTC XMP publication. Coverage includes production
crop/orientation/masks/editorial/history/private fields, both prepared-receipt failures,
authority and later-photo withdrawal at both carriers, same-byte source replacement,
private-directory substitution, cancelled caller tasks, legacy filenames, staged
inode/content attacks and terminal authority drift. Command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath /private/tmp/aagedal-rooted-develop-focused-tests.xcresult \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateRootedWriteServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchCaptureServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchExecutionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPIPTCPatchXMPPublicationAdmissionServiceTests' test
```

Console: `/private/tmp/aagedal-rooted-develop-focused-tests.log`.
Summary: `/private/tmp/aagedal-rooted-develop-focused-summary.json`.

Initial restricted verification could not write compiler/package caches. Normal-access
verification used existing caches and development signing; one signing attempt failed
when Apple's timestamp service returned no timestamp for a bundled library, and retry
succeeded. Earlier focused runs covered the three existing suites before the new test
file's explicit Xcode target membership was corrected. The new fixture's actor isolation,
private path access and nested test macro were corrected before the final focused run.
Ignored pinned AuraFace and web-runtime resources were copied from the main checkout
and are not source changes.

Repository validation passes with `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`
set to `/private/tmp/aagedal-rooted-develop-module-cache`:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-rooted-develop-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-rooted-develop-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-rooted-develop-repository-final.log`.
Project property-list lint and `git diff --check` pass.

The unfiltered integrated run uses the same configuration without `-only-testing`,
with result bundle `/private/tmp/aagedal-rooted-develop-integrated.xcresult`. It passes
**4,298 tests in 411 suites**: **4,296 passed**, zero failures and the two existing
opt-in Sony fixture skips, in **155.840 seconds** of Swift Testing runtime. Its summary
reports zero runtime warnings. Existing `MDB_MAP_FULL` console observations remain;
this run does not close performance qualification.

Console: `/private/tmp/aagedal-rooted-develop-integrated.log`.
Summary: `/private/tmp/aagedal-rooted-develop-integrated-summary.json`.

The persistent-pipe helper probe passes all **41 tools**. Bundled model validation and
final deep/strict development-signature verification pass after all Xcode activity:

```sh
python3 -B scripts/ci/probe_mcp_helper.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output /private/tmp/aagedal-rooted-develop-helper.json
python3 -B scripts/ci/validate_model_bundle.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
codesign --verify --deep --strict \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
```

Artifact evidence: `/private/tmp/aagedal-rooted-develop-helper.json` and matching
`-helper.log`, `-model.log`, `-signature-final.log`. Restricted signature verification
reported `CSSMERR_TP_NOT_TRUSTED`; normal certificate access passes the final check.
Xcode result-summary extraction also used normal report-cache access.

## Remaining work

Connect this primitive to durable batch prepared/installed mutation evidence and
one-way managed operation linkage, then native consent/Start and terminal presentation.
The current admission executor still uses the existing physical writer and native
review remains read-only. No production execution capability is enabled by this change.
Embedded owned-effect stages and watermark dependency admission remain separate work.
Native end-to-end interaction, actual provider/device, real-volume performance,
accessibility, Instruments and distribution qualification remain open. No release gate
or audit checklist count closes from this physical prerequisite.
