# Cycle 53 — MCP immutable parser snapshots

**State:** IMPLEMENTING for 3.0. The shared automation facade now provides internal
immutable parser input associated with the exact captured carrier revisions. Wiring
production typed readers and the effective resolver into a protocol endpoint remains open.

## Behavior

`capturePhotoSnapshot` retains source, XMP and owned app JSON bytes during the same
anchored reads used to calculate revision tokens. It returns those bytes, the admitted
target, revision tokens and captured source/XMP modification dates for reconciliation.
Consumers must parse the snapshot rather than reopen paths after the reservation ends.
The snapshot is internal, non-Codable and is not returned by any MCP tool.

Source retention is limited to 256 MiB, XMP to 8 MiB and owned JSON to its existing
8 MiB cap. Oversized carriers refuse before allocating their contents. Revision-only
inspection still streams source/XMP without retaining them and keeps its existing
format coverage. These are parser-input memory bounds, not a change to GUI support.
A future effective-metadata tool must disclose these bounds or implement a separately
bounded parser path before claiming support for larger sources.

Snapshots preserve exact bytes, distinguish absent from empty XMP, admit current or
legacy owned JSON, and exclude foreign legacy JSON. All existing anchored-path,
regular-file, hard-link, coherent-generation and final authorization checks apply.
Changes during capture and revoked authorization refuse publication and release the
photo reservation. Immutable bytes remain usable after later on-disk replacement;
these historical snapshots confer no authority to mutate a newer revision.

## Verification

Baseline: `c63bca6`; checkout initially clean. Implementation changes are restricted
to the shared MCP core plus regression coverage. No native UI surface changed.

Tests cover exact bytes and token correspondence, both JSON naming generations,
foreign/absent JSON, empty and maximum-sized XMP, source/XMP size refusal, unchanged
revision-only streaming, source/XMP/JSON replacement, revoked authorization and
reservation release on success/refusal.

Host: arm64 MacBook Pro, macOS 27.0 (26A428).

- Final focused MCP suite: **33 tests / 49 executions**, zero failures/skips;
  `build/qa-mcp-snapshot-focused-20260919-3.xcresult`.
- Repository validation passed; `build/qa-mcp-snapshot-repository-20260919.log`.
- Full serial regression: **2,977 tests / 3,843 executions**, zero failures/skips;
  `build/qa-mcp-snapshot-full-20260919.xcresult`, 137.434-second test operation.
  Four previously documented QoS warnings remain in CaptionSessionTests and
  MetadataEditorReadServiceTests.
- `git diff --check` passed.

The initial sandboxed invocation could not access compiler caches. The approved
retry executed tests and exposed a fixture equality failure between subsecond dates
constructed from `stat` and FileManager. Fixed known modification dates now check both
source and XMP timestamps deterministically; the final focused run passes. Xcode also
emitted previously documented exit-code-zero/no-output compilation diagnostics without
preventing the test run. No manual UI or release-readiness gate is claimed complete.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-mcp-snapshot-focused-20260919-3.xcresult -quiet

xcodebuild test-without-building -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-snapshot-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
```

## Remaining work

Connect production embedded/XMP/app JSON typed parsing to these immutable inputs and
the shared effective resolver, preserving bounded output and revision association.
Production workflow tools, broader operation coordination, FFmpeg Whisper, independent
review and native-client/release evidence remain open. No Phase 5A checkbox is closed.
