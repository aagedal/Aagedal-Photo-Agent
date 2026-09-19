# Cycle 48 — bounded MCP carrier reads

**State:** IMPLEMENTING for 3.0. This fixes blocking special-file admission and
unbounded growth during existing revision/draft inspection. Effective typed IPTC
reads and production mutation tools remain open.

## Behavior

- Source and sidecar descriptor opens now use `O_NONBLOCK` as well as no-follow
  admission. A FIFO sidecar without a writer is rejected immediately by `fstat`,
  instead of blocking the single-threaded STDIO helper inside `openat`. The flag
  does not change regular-file reads. Existing regular-file, hard-link, identity,
  generation and ancestor checks remain in force.
- JSON capture and streaming revision hashes read at most the captured file size
  plus one probe byte. Short reads are supported; early EOF or growth refuses the
  evidence. A continuously appending writer cannot extend the read indefinitely
  or bypass the JSON allocation bound checked before reading. Final generation
  checks still reject same-size changes.
- FIFO regressions cover XMP, current app JSON and legacy app JSON. Each has a
  deadline and a rescue writer so the old implementation fails without hanging
  the test process. Each also verifies that failure releases the photo lease.
  Streaming tests cover chunk boundaries, short reads, continuous growth,
  truncation, negative sizes and empty files.

## Verification

Source baseline `45d77c1` on a clean checkout; tested source contains this cycle's
two Swift changes. Development app 3.0.0 (739), arm64, macOS 27.0 (26A428).
All fixtures are disposable local bytes and FIFOs. No user media, preferences,
credentials or authorized roots are modified by the new tests.

- `scripts/ci/validate_repository.sh` passed, including `git diff --check`.
- Focused MCP suite: **25 tests, zero failures and zero skips**, at
  `build/qa-mcp-bounded-read-focused-20260919-2.xcresult`.
- Complete serial suite: **2,956 tests, zero failures and zero skips**, at
  `build/qa-mcp-bounded-read-full-20260919.xcresult`. Xcode's test operation
  completed in 131.101 seconds. Counts use `xcresulttool` test summary totals.
- The initial sandboxed Xcode run could not write SwiftPM/compiler caches outside
  the workspace. The approved rerun uses the existing Xcode cache locations.
  Xcode emitted the previously observed `SwiftCompile ... exit code 0 but produced
  no further output` diagnostics for unrelated test sources, but completed with
  exit code zero; the result bundle confirms the focused tests passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -only-testing:'Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-mcp-bounded-read-focused-20260919-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-bounded-read-full-20260919.xcresult -quiet
```

## Remaining work

Connect effective `get_photo_metadata` to shared production embedded/XMP parsing
and reconciliation, retaining bounded output and exact carrier revision evidence.
Complete the other production operation tools, GUI/MCP coordination, FFmpeg
Whisper, native-client validation and the remaining release gates. This bounded
read correction does not close a Phase 5A feature checkbox or establish release
readiness.
