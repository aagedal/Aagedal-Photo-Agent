# Retained-source Develop decoder admission and Whisper transfer cleanup — 2026-10-11

Baseline: `5a19d19`, initially clean. Implementation commits: `22d2a51` (Whisper cleanup)
and `79c8369` (Develop decoder admission). Tests ran on the exact committed source contents;
documentation follows separately. State remains **IMPLEMENTING**. No whole release gate closes.

## Behavior

`preview_develop_template` now resolves each explicit destination's source-specific state
from the source bytes retained under its rooted photo reservation. It never reopens the photo
pathname. The shared narrow RAW decoder policy applies the same supported decoder selection,
camera/linear profile, scaling and extended-range settings used by interactive Develop. The
helper reads the app's preferences domain explicitly and refuses configuration drift.

RAW admission requires a detected RAW container type, valid dimensions and finite as-shot
neutral values, and forces a small raster decode before returning. This matters because
`CIRAWFilter` can accept ordinary PNG bytes under a `.dng` filename. Non-RAW admission decodes
a bounded ImageIO thumbnail and uses incremental white balance. Saved transient hints are
replaced with the independently resolved destination state; saved crop and unrelated mask
corrections retain the production template preservation rules. Returned layer identifiers
remain ephemeral. The headroom field is the production RAW rendering hint, not a pixel
headroom measurement. There is still no application plan, rendering preview, consent or write.

Signed Whisper lifecycle transfer-cache cleanup now authenticates the lifecycle trust anchor
and checks the retained generation again under the ledger lock. A retained directory descriptor
and no-follow identity checks bind the cache through asynchronous admission. A bounded sweep
preflights every candidate before deleting exact model cache files and model-scoped UUID partials.
Unsafe entries, retired authority or replaced directories refuse. Active downloads hold a
directory lock, protecting their staging bytes even from independent service instances.
Installed releases, ledger bytes, generation and replay floor remain unchanged.

Unscoped legacy partials and other model files are preserved. Cleanup may retire a completed
transfer before installation acquires its ledger admission; installation then safely refuses.
No lease across that handoff is claimed. Cancellation is checked around synchronous work and
between removals; interruption during a sweep may remove a cache prefix, without changing
installed releases or signed authority.

## Verification

Evidence: `build/continuation-7/`. Host: arm64 MacBook Pro, macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a). Debug app: `build/continuation-7/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 741. This is a development candidate.

- Focused tests: **203 tests / five Swift suites**, zero failures/skips
  (`focused-final.xcresult`, `focused-summary.json`). Xcode reports 269 expanded parameter runs.
- Full regression: **3,930 passed, two opt-in Sony skips, zero failures out of 3,932 cases**,
  389 Swift suites, 124.018 seconds (`full.xcresult`, `full-summary.json`, `full.log`).
  Four priority-inversion runtime warnings were reported in `CaptionSessionTests` and
  `MetadataEditorReadServiceTests`; performance acceptance remains open. Focused tests
  reported no runtime warnings.
- Actual persistent STDIO helper: **35 tools**, zero stderr, valid capability discovery and
  malformed/missing/execution-argument refusal (`mcp-helper-final.json`).
- Repository validation, bundled model validation and development signature verification pass
  (`repository-final.log`, `model-bundle-final.log`, `signature-final.log`).
- Actual native launch/open-folder smoke: one test passes in 10.544 seconds using two
  generated disposable photos (`native-smoke.xcresult`, `native-smoke.log`). This validates
  candidate launch and Browser presentation, not the new helper preview or real RAW rendering.
- Independent review found no remaining code blockers after the helper dependency, preference
  routing, lazy RAW output and mislabelled container corrections. New feature GUI acceptance remains open.

The first compile exposed the helper's unavailable native image-cache dependency; extracting
`RAWSourceDecoder` fixed it. A subsequent compile corrected the storage admission argument to
`Set<URL>`. The first focused test run exposed Apple's ordinary-raster RAW-filter acceptance;
requiring detected RAW conformance made the retained-PNG regression pass. Initial dependency
resolution required approved network/compiler-cache access. Test-report extraction and certificate
trust validation likewise required approved cache/trust access. Repository validation instead
uses a workspace compiler cache. The required ignored AuraFace package was provisioned from
the existing main checkout without changing pins. No private camera media or app preferences changed.

Focused command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath build/continuation-7 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPTemplateDiscoveryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDistributionStateStoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDownloadServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/FullScreenImageCacheTests' \
  -resultBundlePath build/continuation-7/focused-final.xcresult
```

The full command removes the focused selectors and uses `full.xcresult`. Repository validation
sets `CLANG_MODULE_CACHE_PATH` to `build/continuation-7/RepositoryModuleCache` before running
`scripts/ci/validate_repository.sh`. Source SHA-256 identities are retained in `source-sha256.json`.
Native smoke uses the same build settings with scheme `Aagedal Photo Agent UI Smoke Tests`,
selector `Aagedal Photo Agent UI Smoke Tests/CoreWorkflowSmokeTests/testLaunchAndOpenFolder`
and result bundle `native-smoke.xcresult`.

## Remaining work

Production Develop-template batches still require retained Primary Develop write/recovery,
whole-set authority, unrelated-XMP preservation, cache invalidation and operation outcomes.
Authentic camera RAW/HDR and decoder-version compatibility need representative fixture evidence.
The 64-pixel admission output, retained-byte limits and dimension bounds do not establish a
maximum native decoder memory footprint or preemption during synchronous decoding.

Production signed catalog/key publishing and Settings integration remain open. Cleanup is an
explicit lifecycle API, with no new native management UI. Broader provider, hardware, privacy,
interoperability, accessibility, packaging and release acceptance gates remain open.
