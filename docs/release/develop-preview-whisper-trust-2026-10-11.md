# Saved-state Develop preview and signed Whisper trust — 2026-10-11

Baseline: `fa1a878`, initially clean. Implementation commits: `f9ff548` (Develop preview)
and `5f7bbe0` (Whisper trust/cleanup). Final tests ran on these exact source contents
before committing; documentation edits were separate. State remains **IMPLEMENTING**.

## Behavior

The bundled helper exposes `preview_develop_template` for one explicit authorized photo,
a canonical lowercase template UUID and its exact content revision. All three current
photo carrier tokens are required. The preview uses the production Develop template
application model to compare saved destination Camera Raw controls with resulting controls,
honor crop inclusion/exclusion, preserve saved target-specific data and regenerate mask/
watermark identifiers with corresponding order references. Template inventory/routing and
photo authority are revalidated. Stale inputs, revoked authority, XMP conflicts and oversized
results refuse. Tests assert unchanged photo, sidecar and template bytes.

This is a saved-state comparison. Decoder/as-shot white balance and HDR headroom admission
remain unresolved. Returned identifiers are ephemeral. No rendering, operation, draft,
consent, write plan or publication authority is created. Production Develop-template
execution and the complete Phase 5A criterion remain open.

Signed Whisper lifecycle installed-model lookup and rollback now authenticate retained
release descriptors against the lifecycle's own trust anchor. Lookup binds the returned
model to that verified generation. Rollback verifies both current and candidate release,
rechecks cancellation and commits through the store's generation-bound byte transaction.
Foreign-trust refusal preserves exact ledger/model bytes and rollback authority; successful
rollback preserves the accepted high-water sequence and consumes its candidate.
An explicit generation-bound interrupted-install cleanup wrapper now authenticates lifecycle
authority before the store's bounded sweep. It preserves retained releases, ledger, generation
and other-model staging; refused foreign/stale/cancelled requests delete nothing. Transfer-cache
cleanup and production signed catalog/key/Settings integration remain open.

## Verification

Evidence directory: `build/continuation-6/`. Host: arm64 macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a). Debug app: `build/continuation-6/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0, build 741. This is a development build, not a final notarized release.

Focused verification passes **139 tests / three suites**, zero failures/skips, in 2.469
seconds (`focused-final.xcresult`, `focused-summary.json`). An additional successful tool
dispatch assertion was added afterward and is included in final integrated verification.
The first focused compile failed on the conflict fixture's `setAttributes` argument label;
correcting it to `ofItemAtPath` resolved the failure.

The actual bundled persistent-STDIO probe passes with **35 tools**, zero stderr, and
malformed/missing/execution-argument refusal for the new preview (`mcp-helper.json`).
Repository checks (`repository-final.log`), required bundled model validation
(`model-bundle-final.log`) and development signature verification (`signature.log`) pass.
Independent source/security review found no blockers after generation-binding, comment
and capability corrections. No native GUI changes or new UI qualification are claimed.
Final source identities are retained in `source-sha256.json`.

Final integrated regression passes **3,920 passed, two skipped, zero failed out of
3,922 reported cases**, across 389 Swift suites in 125.618 seconds (`full.xcresult`,
`full-summary.json`, `full.log`). The two opt-in Sony cases remain skipped; no new
camera evidence is claimed. Existing LMDB map-full and QoS diagnostics retain broader
runtime/performance qualification. Initial sandboxed xcresult summary extraction required
an approved rerun for Xcode TestReport cache access; the resulting summary is retained. The reviewed ignored AuraFace package was copied
from the main checkout; package pins remain unchanged. Initial sandboxed preparation
failed on compiler-cache access and pinned submodule retrieval. Approved reruns permit
required cache and network access. No private photo fixtures or preferences are changed.

Focused command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath build/continuation-6 \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -only-testing:'Aagedal Photo Agent Tests/MCPTemplateDiscoveryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/WhisperModelDistributionStateStoreTests' \
  -resultBundlePath build/continuation-6/focused.xcresult
```

Integrated regression uses the same command without the focused selectors. Repository
checks use `scripts/ci/validate_repository.sh`; actual helper protocol checks use
`scripts/ci/probe_mcp_helper.py`. No complete release gate closes from these bounded changes.
