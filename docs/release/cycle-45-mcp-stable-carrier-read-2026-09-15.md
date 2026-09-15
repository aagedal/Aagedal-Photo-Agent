# Cycle 45 — stable carrier reads and bounded STDIO errors

**State:** IMPLEMENTING for 3.0. This tightens the read-only prerequisite for effective
`get_photo_metadata`; it does not resolve IPTC carrier precedence or permit a mutation.

## Behavior

- Source, adjacent XMP and exact-owner app JSON reads now compare file change time as well
  as identity, size and modification time before and after an anchored, no-follow read.
  They also compare the path entry with the opened descriptor. A same-size in-place
  rewrite with restored modification time changes its opaque revision token; a rewrite
  during an individual carrier read refuses that read as changed.
- STDIO rejects a complete oversized request line with a bounded JSON-RPC Invalid Request
  response. It no longer allocates a full maximum-sized dummy input to generate the
  error. Subsequent newline-delimited requests and a final request at EOF still run.

## Verification

Source baseline `c69575f` on clean `main`, development 3.0.0 (738), arm64 macOS 27.0.
Disposable photo and pipe fixtures contain no user media or credentials.

- The focused MCP selection passed **19 tests, zero failures and zero skips** at
  `build/qa-mcp-read-stability-focused-2.xcresult` before the identical-byte variant
  of the new rewrite test was finalized. The final-source complete serial suite then
  passed **3,777 executions, zero failures and zero skips** at
  `build/qa-mcp-read-stability-final-full.xcresult`. Xcode reported 129.991 seconds for
  the test operation. Its summary reports four priority-inversion runtime warnings in
  Caption Session and Metadata Editor read tests, with none attributed to MCP source.
- `scripts/ci/validate_repository.sh` and `git diff --check` passed again on the
  final source and documentation.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-read-stability-final-full.xcresult -quiet
```

## Remaining work

Complete `get_photo_metadata` needs the production descriptive reader, reconciled
embedded/XMP/app values, typed structured fields, pending/conflict state and exact
revision-bound effective output. Template/provider discovery, operation status,
guarded workflow tools, FFmpeg Whisper, real-client and release evidence remain open.
An external writer changing an earlier carrier after its read and before all carriers are
captured remains outside this cycle's per-carrier stability check; the effective reader
must verify a coherent final snapshot before publishing merged values.
No Phase 5A checklist criterion is closed by this cycle.
