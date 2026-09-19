# Cycle 56 — Effective metadata field provenance

State: IMPLEMENTING. Baseline `2cf9565`, initially clean checkout.

The shared effective metadata resolver now returns the selected carrier for every persisted
editorial field. The bounded MCP projection includes this `fieldCarriers` map and refuses
missing or unexpected provenance keys. It remains an internal app-side projection.

The map describes the resolver's selection rule, including absence and explicit clears;
it is not proof of authorship, authenticity, or physical field presence. Descriptive XMP
replacement selects XMP even for cleared fields or values identical to embedded values.
Localized Titles inherit embedded alternatives only when the XMP value is nil; an empty
array selects XMP. Capture date requires a nonempty XMP value; GPS, rating and label require
a non-nil value, preserving zero and empty-label semantics. The legacy creator alias follows
the selected creators array. A stale conflicting XMP selects embedded editorial fields,
while a pending app-sidecar record selects all editorial fields, including clears.
Develop-only/sparse XMP still permits independent GPS/rating/label selection.

No effective values or interactive editing behavior change. The helper endpoint, publication
authorization, production workflow tools, FFmpeg Whisper and broader release gates remain
open. No acceptance checkbox is closed and no native-client validation is claimed.

## Verification

Generated image and in-memory metadata fixtures only; no user photos or preferences changed.
Host: arm64, macOS 27.0 (26A428), Debug test host.

Regression coverage includes equal-valued replacement, descriptive clears, inherited Titles,
empty capture date, per-coordinate GPS selection, zero rating, empty label, legacy creator
alias, sparse XMP, localized clear, conflicting XMP, pending/saved drafts, exact protocol
key coverage and refusal of incomplete/unexpected provenance.

- Focused validation passes **27 tests / 51 executions**, zero failures/skips:
  `build/qa-mcp-provenance-focused-3.xcresult`.
- Complete final-source serial validation passes **2,991 tests / 3,878 executions**,
  zero failures/skips, 135.176-second test operation:
  `build/qa-mcp-provenance-full.xcresult`.
- The four previously recorded QoS warnings remain in CaptionSessionTests and
  MetadataEditorReadServiceTests.
- Repository validation passes: `build/qa-mcp-provenance-repository-final.log`.
- `git diff --check` passes.

The first sandbox invocation could not write standard compiler/package caches. An approved
retry reached compilation; a fixture argument-order error was corrected before rerunning.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPMetadataSnapshotReaderTests' \
  '-only-testing:Aagedal Photo Agent Tests/SidecarReconciliationTests' \
  -resultBundlePath build/qa-mcp-provenance-focused-3.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-provenance-full.xcresult -quiet

scripts/ci/validate_repository.sh
git diff --check
```
