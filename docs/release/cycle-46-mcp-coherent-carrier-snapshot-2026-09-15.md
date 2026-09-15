# Cycle 46 — coherent MCP carrier evidence

**State:** IMPLEMENTING for 3.0. This closes a read consistency gap in the prerequisite
for effective `get_photo_metadata`; it does not reconcile IPTC or authorize a mutation.

## Behavior

- `inspect_photo_revision` and `inspect_app_photo_draft` now recheck source, adjacent XMP,
  each current/legacy app JSON candidate, and the private metadata directory after all
  carrier reads. Final checks use the granted-root directory descriptors, no-follow path
  entries, file identity, link count, size, modification time and change time. A carrier
  that appeared, disappeared, was replaced or changed after its earlier read causes
  `photoChanged` rather than publishing mixed-generation tokens and draft values.
- The final pass compares filesystem generations without hashing the entire source a
  second time. It retains the existing per-carrier anchored content hash and cross-process
  photo lease. The only added callback is an injectable capture checkpoint for a
  deterministic race regression; production uses an empty callback.

## Verification

Baseline `0ab8af7` on clean `main`, development 3.0.0 (738), arm64 macOS 27.0.
Disposable photo, XMP and JSON fixtures contain no user media or credentials.

- Focused MCP selection: **20 tests, zero failures and zero skips** at
  `build/qa-mcp-coherent-carriers-focused-2.xcresult`. Its new regression changes
  source, existing XMP, owned app JSON, or an initially absent XMP carrier between
  capture and publication; every case refuses the combined result.
- The final-source complete serial suite passed **3,778 tests, zero failures and zero
  skips** at `build/qa-mcp-coherent-carriers-full.xcresult`. Xcode reported 132.050
  seconds for the test operation. The result bundle reports four priority-inversion
  runtime issues in existing Caption Session and Metadata Editor read tests, with none
  attributed to the MCP fixture.
- `scripts/ci/validate_repository.sh` and `git diff --check` passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-coherent-carriers-full.xcresult -quiet
```

## Remaining work

Complete `get_photo_metadata` still needs the production embedded/XMP reader, typed
structured values, effective carrier precedence, pending/conflict state and bounded
revision-bound output. An external writer can still change a carrier immediately after
the final check; Photo Agent's lease coordinates its own processes, not arbitrary
third-party writers. Production workflow facade/tools, broader GUI/MCP operation
coordination, FFmpeg Whisper, real-client and release evidence remain open. No Phase 5A
checkbox is closed by this bounded prerequisite.
