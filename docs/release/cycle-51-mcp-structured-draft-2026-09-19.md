# Cycle 51 — MCP structured editorial draft records

**State:** IMPLEMENTING for 3.0. Owned JSON draft inspection now includes structured
editorial records. Effective embedded/XMP reconciliation remains open.

## Behavior

`inspect_app_photo_draft` preserves ordered supplier identifier/name pairs,
independent locations Created/Shown (including numeric coordinates and altitude),
creator contact information, Media Topics and Genre vocabulary records. Only known
production persisted properties are exposed. Unknown nested properties are omitted;
history, transcripts and Develop values remain outside this tool's field scope.
The field-scope marker is now `editorial-app-json-descriptive-draft`.

Missing/null properties remain absent, while empty lists, objects and strings remain
explicit values. Reads do not normalize or flatten stored text. CV records require a
string term identifier; this inspection does not claim vocabulary/URI validation or
mutation authority. Coordinates reject strings and JSON booleans without coercion.

Structured lists and nested string arrays have 128-entry limits. Strings have a
32,768-byte limit (1,024 bytes for array items); every emitted string shares the
existing 65,536-byte aggregate budget with scalar fields and localized Titles.
Malformed or oversized known properties refuse the whole draft read. The existing
coherent carrier capture, root authority and reservation boundaries are retained.

## Verification

Baseline: `0a70acd`; checkout initially clean. Changed source comprises the draft
field catalog and its tool description, plus focused regression coverage. Tests use
the production Codable models to verify the output shape, pairing, ordering and
clears, then inject invalid shapes/types, count limits, Unicode byte limits and an
aggregate overflow spanning scalar and structured values. Refusal cases verify
that the photo reservation is released.

Host: arm64 MacBook Pro, macOS 27.0 (26A428).

- Focused MCP suite: **28 tests / 36 executions**, zero failures/skips;
  `build/qa-mcp-structured-focused-20260919-2.xcresult`.
- Repository validation passed;
  `build/qa-mcp-structured-repository-20260919.log`.
- Full serial regression: **2,972 tests / 3,830 executions**, zero failures/skips;
  `build/qa-mcp-structured-full-20260919.xcresult`, 138.764-second test operation.
- `git diff --check` passed.

The first sandboxed Xcode attempt could not write compiler caches. The approved
rerun passed. The full suite reports four previously observed QoS warnings in
CaptionSessionTests and MetadataEditorReadServiceTests; this cycle does not fix them.
This read-only protocol extension has no new native UI surface and
closes no native-client or release-readiness gate.

## Reproduction

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-mcp-structured-focused-20260919-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-structured-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
```

## Remaining work

Connect bounded coherent carrier capture to production embedded/XMP readers and
shared effective metadata resolution. Remaining typed scalar fields, production
workflow tools, broader operation coordination, FFmpeg Whisper, independent review
and native-client/release evidence remain open.
