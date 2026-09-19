# Cycle 54 — Typed metadata from immutable snapshots

State: IMPLEMENTING. Baseline `d18c831`, initially clean checkout.

The new app-side `MCPMetadataSnapshotReader` parses captured source bytes with
SwiftMediaMetadata and the production IPTC dictionary adapter, captured XMP with the
production sidecar parser, and owned JSON with the production typed sidecar decoder.
It uses the shared effective resolver and returns matching carrier revision tokens.
It never reopens source paths. Header dimensions for angled crop conversion come from
ImageIO operating on the captured data with pixel caching disabled. TIFF-based RAW
extension disambiguation follows the production reader for admitted photo formats.

Reconciliation now has a pure captured-date overload. The URL-based GUI entry retains
its existing short circuit for absent/equal descriptive content. Snapshot reads use
captured modification dates, so subsequent file changes cannot alter their verdict.
Pending drafts retain existing clear, orientation and Develop precedence; saved JSON
leaves physical metadata authoritative. Unknown pending/schema state, malformed typed
JSON, absent/null metadata records, incorrect ownership and unreadable image/XMP inputs
refuse rather than silently producing empty effective metadata.

This is an internal app-side adapter, not a protocol endpoint. The helper still needs
its typed-reader dependency boundary, bounded serialized output, final authorization
at publication, and production real-client verification. Historical revisions do not
grant mutation authority. The existing 256 MiB source and 8 MiB XMP/JSON capture limits
continue to apply; no broader format/output support or release gate is claimed.

## Verification

Generated four-by-two JPEG fixtures carry an embedded Headline and an adjacent XMP
Headline; no user media is used. Tests supply a nonexistent source path to prove the
reader uses captured data, vary captured dates to exercise stale-XMP selection, verify
pending/saved JSON and explicit clears, assert revision association, preserve embedded
metadata when XMP is absent, and exercise malformed/unknown carriers.

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Debug test-host build.
No native UI surface changed and no native-client acceptance is claimed.

- Focused reader/reconciliation validation: **19 tests / 34 executions**, zero
  failures/skips; `build/qa-mcp-typed-snapshot-20260919-3.xcresult`.
- Repository validation passes; `build/qa-mcp-typed-snapshot-repository-20260919.log`.
- Full final-source serial regression: **2,983 tests / 3,861 executions**, zero
  failures/skips; `build/qa-mcp-typed-snapshot-full-20260919.xcresult`, 143.331-second
  test operation. The four previously recorded QoS warnings remain in
  CaptionSessionTests and MetadataEditorReadServiceTests.
- `git diff --check` passes.

The initial sandbox invocation lacked compiler-cache access; the approved retry ran
and exposed tolerant empty-XMP parsing. The adapter now requires well-formed RDF XML,
refuses DTDs and excessive nesting, and preserves the production packet-padding
convention. Focused regressions include empty valid RDF, padding, malformed XML,
unrelated XML and DTD input. The final focused run passes. Existing Xcode
exit-code-zero/no-output diagnostics appeared during the first compile.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPMetadataSnapshotReaderTests' \
  '-only-testing:Aagedal Photo Agent Tests/SidecarReconciliationTests' \
  -resultBundlePath build/qa-mcp-typed-snapshot-20260919-3.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-typed-snapshot-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
```
