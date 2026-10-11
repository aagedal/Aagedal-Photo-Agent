# Develop capture, Whisper transfer cleanup and face pruning — 2026-10-11

Baseline: `5a19d19`, initially clean. State remains **IMPLEMENTING**. Two implementation
sub-agents owned separate Develop and Whisper slices; a third independently reviewed
those changes and the coordinator's face-scan fix. No blocking review findings remain.
Implementation commits: `2ce5bf9` (Develop capture), `4c502a8` (Whisper transfer cleanup),
and `e9746a9` (face pruning). Final checks use those exact application source contents;
only documentation is dirty. Source hashes are in `source-sha256.json`.

## Behavior

Primary Develop now builds its retained request from a reusable immutable
`PrimaryDevelopWriteCapture`. The live editor and future automation callers can share
the same destination-specific baseline, scalar/structured replacement, history,
reset and watermark dependency policy. Construction performs no filesystem work.
Render-only white-balance/HDR hints do not trigger a Develop replacement. An XMP-only
ancestor cannot acknowledge embedded Develop or orientation state. Foreign photo,
folder or editor-load ancestry, missing source revision and missing XMP evidence
become failed captures; foreign ancestry cannot provide baselines or history.
An observed absent XMP snapshot remains valid evidence.

This extraction is groundwork for guarded template execution. It does not perform
destination decoder/as-shot/HDR admission, grant native consent, create an MCP
application plan or expose a production Develop-template executor.

Signed Whisper lifecycle now has an explicit generation-bound interrupted-transfer
cleanup action. New transfer partials carry their model ID. Cleanup authenticates
the lifecycle trust anchor and retains the store's generation lock throughout its
synchronous sweep. A shared cache-directory lock held during downloads excludes
cleanup while another cooperating service instance is transferring. The bounded
sweep validates all selected private regular single-link files before deletion,
rechecks their identity and uses descriptor-relative deletion. Published cache
files, other-model partials, legacy unscoped partials, retained installed releases,
ledger bytes and rollback authority survive. Stale, cancelled, corrupt, foreign or
missing authority refuses. Unsafe candidates, excessive inventories and redirected
cache directories refuse. Cleanup never initiates a download.

Production signed catalog/key/Settings integration remains open. Legacy partials
lack model ownership and require a separate recovery policy. Cooperating locks do
not protect against arbitrary external writers. An error after deletion begins
does not establish that every candidate remains; maintenance is safe to reinspect.

Removal-only incremental face scans now persist their pruned faces, groups, jersey
numbers and file signatures through the existing final-save path while retaining
the folder reservation. Only a truly unchanged inventory skips persistence.
Surviving named groups retain their name and receive a surviving representative.
Save failure reports an error and preserves the original durable document.
This does not introduce a helper face-scan executor or change the existing final-save
presentation/recovery policy.

## Verification

Evidence directory: `build/continuation-7/`. The ignored pinned AuraFace package was
copied from the main checkout and passes `build_auraface_coreml.py verify`. Existing
package checkouts were copied into isolated derived data; package pins are unchanged
and automatic package resolution/updates are disabled.

Host: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
App: `build/continuation-7/Build/Products/Debug/Aagedal Photo Agent.app`, version 3.0.0,
build 741. This is a development verification build, not the final notarized candidate.

Focused verification passes **136 tests / five Swift suites**, zero failures/skips,
in 1.600 seconds (`focused.xcresult`, `focused-summary.json`, `focused.log`). Xcode's
device summary reports 195 expanded executions. Regressions cover capture semantics,
foreign deep ancestry/missing evidence, signed cleanup authority and generation races,
active transfers across service instances, unsafe/bounded/redirection refusals,
and four removal-only success/save-failure cases with and without surviving faces.

The actual persistent-STDIO helper probe passes with **35 tools**, zero stderr,
strict argument refusal and clean exit (`mcp-helper.json`). Required bundled-model
validation and development signature verification pass (`model-bundle.log`,
`signature-approved.log`). Sandboxed signature verification could not resolve developer
trust; the approved check succeeds.

Final integrated regression passes **3,940 passed, two skipped, zero failed out of
3,942 reported cases**, across 390 Swift suites in 126.546 seconds (`full.xcresult`,
`full-summary.json`, `full.log`). The two opt-in Sony cases provide no new authentic
camera evidence. Four existing Caption/metadata-read QoS warnings and test-host
LMDB map-full diagnostics retain broader runtime/performance qualification.
Final repository validation passes (`repository-final.log`), including model
discovery, generated documentation, component provenance and privacy checks.
The initial sandboxed Xcode and model-discovery invocations could not write normal
compiler caches; approved reruns resolve that preparation restriction.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 \
  -derivedDataPath build/continuation-7 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -resultBundlePath build/continuation-7/full.xcresult
scripts/ci/validate_repository.sh
python3 -B scripts/ci/probe_mcp_helper.py \
  'build/continuation-7/Build/Products/Debug/Aagedal Photo Agent.app/Contents/MacOS/photo-agent-mcp'
```

Focused verification adds `-only-testing:` selectors for `ActivityHistoryTests`,
`PrimaryDevelopWriteServiceTests`, `PrimaryDevelopWriteRequestBuilderTests`,
`WhisperModelDistributionStateStoreTests` and `WhisperModelDownloadServiceTests`.

Native computer-use availability was checked. Another Photo Agent Debug instance is
already running, so this cycle does not run UI tests that would terminate that
session. No new native, accessibility, hardware, real-provider, real-server or full
release-acceptance evidence is claimed. No user photos or app preferences are changed.

## Next implementation work

1. Admit exact destination decoder/as-shot/HDR evidence, then connect the shared
   Develop capture to retained template authority, explicit native review, final
   whole-set revalidation and truthful durable operation results.
2. Integrate the signed Whisper production catalog, trust key and Settings lifecycle;
   qualify real interrupted-transfer/install/recovery behavior.
3. Extract a typed admitted complete-folder face-scan handle and terminal receipt
   before adding authenticated native consent and helper execution.
4. Continue physical IPTC commit tools and the broader native/external qualification
   gates listed in the authoritative plans.
