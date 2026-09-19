# Cycle 50 — MCP localized draft Titles and strict header types

**State:** IMPLEMENTING for 3.0. The existing owned-draft inspection now preserves
localized Title alternatives independently of Headline. This is still unreconciled
app JSON, not effective IPTC or mutation authority.

## Behavior

`inspect_app_photo_draft` returns `localizedTitles` using the production persisted
`languageTag`/`value` shape, preserving order, verbatim language tags and explicit
empty-array clears. Missing or null alternatives remain unmodeled. The existing
`title` key continues to mean Headline. Unknown properties are not exposed.

The reader limits alternatives to 128 entries, language tags to 1,024 UTF-8 bytes,
each Title to 32,768 UTF-8 bytes, and all descriptive values together to 65,536
UTF-8 bytes. Malformed or oversized alternatives refuse the entire draft read.

Schema and pending-change fields now use strict Codable decoding. JSON booleans
cannot masquerade as schema integers, and numeric pending flags cannot masquerade
as booleans through Foundation bridging. Uninterpretable headers do not expose
fields. Revision inspection remains available with an unknown draft state.

## Verification

Baseline: `bc708f8`; checkout initially clean. Regression tests encode the production
`LocalizedMetadataText` model, verify ordered alternatives/clear/null behavior and
independent Headline, and exercise malformed types and count/UTF-8/aggregate limits.
Malformed-draft cases also check that the photo reservation is released.

Host: arm64 MacBook Pro, macOS 27.0 (26A428).

- Focused MCP suite: **27 tests / 35 parameterized executions**, zero failures/skips,
  `build/qa-mcp-title-focused-20260919-2.xcresult`.
- Final-source complete serial suite: **2,971 tests / 3,829 parameterized executions**,
  zero failures/skips, `build/qa-mcp-title-full-20260919.xcresult`.
  Test operation: 140.824 seconds.
- Repository validation passed, `build/qa-mcp-title-repository-final-20260919.log`.
- `git diff --check` passed.

The initial sandboxed attempt could not access compiler caches; the approved Xcode
run succeeded. The focused build emitted the previously observed exit-code-zero/no-output
compiler diagnostics. Review corrected an accidental transport text-key edit before the
final-source full run; that run also includes the added Title size-bound regressions.
The full run reports four existing QoS warnings across CaptionSessionTests and
MetadataEditorReadServiceTests; this cycle does not claim to fix them.

## Remaining work

Connect production embedded/XMP typed parsing and the shared effective-metadata
resolver to bounded coherent MCP capture. Production workflow tools, broader
operation admission/status, FFmpeg Whisper and release validation remain open.
No native UI or release-readiness gate is closed by this change.

## Reproduction

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-mcp-title-focused-20260919-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-title-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
```
