# Cycle 52 — MCP typed draft scalars

**State:** IMPLEMENTING for 3.0. Owned draft inspection now includes the remaining
persisted editorial scalar fields. Effective embedded/XMP reconciliation remains open.

## Behavior

`inspect_app_photo_draft` now exposes capture date, digital source type, label, the
legacy scalar creator, urgency, rating, latitude and longitude. Integers remain
integers; GPS values remain finite numbers. Missing/null fields remain absent, while
zero, rejected ratings and empty strings remain explicit values. Legacy `creator`
and current `creators` are inspected independently, without normalizing stored text
or applying the production reader's fallback precedence.

Numeric strings, booleans, fractional integer fields, integer overflow and invalid
shapes refuse the complete read. Added text fields share the existing per-string and
aggregate UTF-8 limits. The same finite-number decoder handles structured locations
and scalar GPS. Stored enum strings and numeric values are not validated against
editor ranges or vocabulary membership: this endpoint inspects unreconciled JSON,
continues to return `effectiveIPTCResolved: false`, and grants no mutation authority.
History, transcripts and Develop state remain excluded.

## Verification

Baseline: `fe4b4b6`; checkout initially clean. Changed implementation comprises the
MCP field catalog and tool description; no native UI surface changed. Regression
coverage encodes production `IPTCMetadata`, verifies exact values and clears, checks
legacy/current creator independence and refuses malformed/oversized values. Each
refusal also verifies that the photo reservation can be reacquired.

Host: arm64 MacBook Pro, macOS 27.0 (26A428).

- Focused MCP suite: **29 tests / 37 executions**, zero failures/skips;
  `build/qa-mcp-scalars-focused-20260919-2.xcresult`.
- Repository validation passed;
  `build/qa-mcp-scalars-repository-20260919.log`.
- Full serial regression: **2,973 tests / 3,831 executions**, zero failures/skips;
  `build/qa-mcp-scalars-full-20260919.xcresult`, 132.589-second test operation.
- `git diff --check` passed.

The initial sandboxed Xcode invocation could not write compiler caches; the approved
retry passed. Reading the result summary also required approved report-cache access.
The full run reports four previously documented QoS warnings in CaptionSessionTests
and MetadataEditorReadServiceTests; these are unchanged. No native-client or
release-readiness gate is closed by these protocol tests.

## Reproduction

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-mcp-scalars-focused-20260919-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-scalars-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
```

## Remaining work

Connect bounded coherent carrier capture to production embedded/XMP readers and the
shared effective metadata resolver. Production workflow tools, broader operation
coordination, FFmpeg Whisper, independent review and native-client/release evidence
remain open.
