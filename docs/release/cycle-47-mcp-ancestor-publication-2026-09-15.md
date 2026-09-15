# Cycle 47 — MCP ancestor identity at publication

**State:** IMPLEMENTING for 3.0. This closes one path-association prerequisite for
effective `get_photo_metadata`; it does not add typed effective IPTC reads or mutation
authority.

## Behavior

- An MCP photo inspection retains the authorized-root descriptor and every no-follow
  ancestor descriptor until the combined source, XMP and app-JSON evidence is ready.
  Opening each child checks its current path entry against the opened descriptor.
- Before publication, the facade checks that the root still occupies its authorized
  pathname and each nested directory still occupies the entry through which it was
  opened. A folder moved away or replaced during carrier capture returns
  `photoChanged`. Existing per-carrier generation checks and final path authorization
  remain in place. The descriptors close on every success or failure path.
- A disposable nested-photo regression retargets an ancestor after carrier reads,
  installs a different photo at the same pathname and verifies refusal. Restoring the
  original directory permits a fresh inspection with the original revision tokens.

## Verification

Source baseline `d75fbe7` on clean `main`; tested source contained this cycle's two
uncommitted Swift changes. Development app 3.0.0 (738), arm64 MacBook Pro, macOS 27.0.
The race fixture contains only disposable text bytes under a temporary root. No user
media, credentials or preferences were changed.

- Focused MCP selection: **21 tests, zero failures and zero skips** at
  `build/qa-mcp-ancestor-chain-focused-2.xcresult`.
- Final-source complete serial suite: **3,780 expanded executions, zero failures and
  zero skips** at `build/qa-mcp-ancestor-chain-full.xcresult` (2,937 logical tests;
  Xcode test operation 144.137 seconds). Four existing priority-inversion runtime
  warnings point to Caption Session and Metadata Editor read tests, with none in MCP.
- `scripts/ci/validate_repository.sh` and `git diff --check` passed. The first
  sandboxed Xcode attempt stopped during dependency resolution because compiler and
  SwiftPM caches were outside the writable workspace; the approved rerun reached and
  passed the focused suite.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-ancestor-chain-full.xcresult -quiet
```

## Remaining work

Complete `get_photo_metadata` still needs the production embedded/XMP reader,
typed bounded effective descriptive values, carrier precedence and conflict/pending
state. Arbitrary external writers can change carriers immediately after the last
check; later writes must compare exact revision tokens and retain the shared
transaction boundaries. Production operation tools, broader GUI/MCP admission,
FFmpeg Whisper, native client and release validation remain open. No Phase 5A
checkbox is closed by this read-only prerequisite.
