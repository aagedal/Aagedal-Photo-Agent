# Develop rooted mutation evidence — 2026-10-18

Continues the rooted sidecar writer from clean baseline `70f3943`.
State remains IMPLEMENTING; the broad audit remains 66 of 75.

## Implemented boundary

`DevelopTemplateRootedMutationStore` retains a single reviewed photo's original
admission evidence, ordered batch intent, root/source identity, carrier revisions and
original XMP/app bytes. It uses the existing anchored, locked, bounded and synced
`AutomationOperationPersistence`; synchronous callbacks run on the retained metadata
filesystem executor, without awaiting between physical installs. Source image bytes
are not duplicated in the journal.

The journal advances only through XMP prepared, XMP installed, app prepared and app
installed. Each prepared stage retains exact candidate bytes, the staged physical
identity and the exact destination, including sole legacy app-sidecar filenames. An installed receipt must match that identity and candidate, preserve the
source generation, and preserve the other carrier's expected generation. Retaining an
identical original binding preserves all existing progress; another binding, replayed
stage, out-of-order stage or conflicting receipt is refused.

The rooted writer now requires a synchronous installed-retention callback. It saves
its physical snapshot before invoking that callback, so a retention failure stops the
next carrier and returns the exact physical outcome. The journaled adapter binds both
prepared and installed callbacks to the original material. Loading evidence does not
create consent or reconstruct an executable request; even an app-installed record is
not a verified batch completion. An unresolved preparation conservatively means that
publication may have occurred.

Loaded records validate checksums, schema version, ordered stages, physical identities,
revision bounds and original review consistency. The original app sidecar must agree
with the captured presence and persisted known fields, while unknown fields remain
in the exact original bytes. Independent review identified missing material validation
on load and missing original-app coherence checks; both are fixed and covered by
checksummed-corruption regressions. No review objections remain within this boundary.

## Verification

Environment: arm64 macOS 27.0.1 (26A434), development app 3.0.0/build 742. Fixtures are generated PNGs, templates and
private journals under `/private/tmp`; no user photos or app preferences are changed.
The ignored pinned AuraFace package and web runtime were copied from the main checkout
for the normal bundled build. They are not source changes.

Repository validation passes with compiler module caches redirected into `/private/tmp`:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aagedal-develop-journal-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/aagedal-develop-journal-module-cache \
scripts/ci/validate_repository.sh
```

Console: `/private/tmp/aagedal-develop-journal-repository-final.log`.
Swift frontend parsing of the two production files and the test suite passes.

The initial restricted Xcode attempt could not access package caches/network. The
normal-access build refreshed the existing pinned package working copies. That build
compiled the app before the final destination callback change and then encountered
stale-signature test compilation errors; it ran no tests. A subsequent test compilation exposed missing inner `try` markers and a nested
`#require`; those test macro mistakes were corrected before the final focused run.
Only a production comment changed between focused and integrated verification.

Final focused command:

```sh
xcodebuild -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 2 \
  -derivedDataPath /private/tmp/aagedal-settings-search-build \
  -clonedSourcePackagesDirPath /private/tmp/PhotoAgentModelsDerivedData/SourcePackages \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath /private/tmp/aagedal-develop-journal-focused-4.xcresult \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateRootedWriteServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchCaptureServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopTemplateBatchExecutionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPIPTCPatchXMPPublicationAdmissionServiceTests' test
```

Console: `/private/tmp/aagedal-develop-journal-focused-4.log`.
The focused run passes **100 tests in four suites**, zero failures/skips, in
**10.877 seconds** of Swift Testing runtime. The new five tests cover current/legacy
success, both installed-retention failures, transition/substitution refusal, eight
checksummed-corruption cases and both interrupted preparations. Existing source and
later-photo drift, staged inode/content substitution, authorization and cancellation
coverage also passes. Existing `MDB_MAP_FULL` console observations remain; this is
not performance qualification.

Both result summaries report zero runtime warnings. The integrated run uses the same
configuration without `-only-testing`, with result bundle
`/private/tmp/aagedal-develop-journal-integrated.xcresult`. It passes **4,303 tests in
411 suites**: **4,301 passed**, zero failures and the two existing opt-in Sony fixture
skips, in **149.766 seconds** of Swift Testing runtime.

Consoles and summaries:

- `/private/tmp/aagedal-develop-journal-focused-4.log`
- `/private/tmp/aagedal-develop-journal-focused-summary.json`
- `/private/tmp/aagedal-develop-journal-integrated.log`
- `/private/tmp/aagedal-develop-journal-integrated-summary.json`

The persistent-pipe helper probe passes all **41 tools**. Bundled model validation
and deep/strict development-signature verification pass after all Xcode activity:

```sh
python3 -B scripts/ci/probe_mcp_helper.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp' \
  --output /private/tmp/aagedal-develop-journal-helper.json
python3 -B scripts/ci/validate_model_bundle.py \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
codesign --verify --deep --strict \
  '/private/tmp/aagedal-settings-search-build/Build/Products/Debug/Aagedal Photo Agent.app'
```

Evidence: `/private/tmp/aagedal-develop-journal-helper.json` and matching `-helper.log`,
`-model.log`, `-signature.log`. Result-summary extraction required normal report-cache
access. `git diff --check` passes. No native interaction acceptance is claimed: this
unit exposes no new native action and remains an internal execution prerequisite.

## Remaining work

Connect the per-photo journals to durable batch checkpoints, recovery inventory and
one-way managed operation linkage. Then connect native consent/Start and exact terminal
presentation. The existing admission executor still uses its previous physical writer;
no native execution capability is enabled by this change. Embedded owned-effect stages,
watermark dependency admission, native end-to-end interaction, provider/device and
real-volume performance, accessibility, Instruments and distribution qualification
remain open. No release gate or audit checklist count closes from this prerequisite.
