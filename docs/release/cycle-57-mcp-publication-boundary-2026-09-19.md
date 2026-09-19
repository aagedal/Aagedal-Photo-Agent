# Cycle 57 — Effective metadata publication boundary

State: IMPLEMENTING. Baseline `e06b333`, initially clean checkout.

The app-side effective metadata reader now has an authorized `inspectPhoto` entry point.
It captures immutable carrier bytes, parses production metadata and builds the bounded
protocol projection while retaining the shared photo reservation and anchored directory
handles. After parsing and output validation, it rechecks all source/sidecar path entries,
including absent candidates, private metadata storage, every retained ancestor and current
folder authorization. A provisional result is returned only when those checks pass.

This reuses the existing carrier identity checks without reopening or hashing each large
source a second time. Parser errors, output refusal and revalidation failures release the
reservation and handles through the existing cleanup paths. The snapshot-only API remains
available for historical parsing; callers needing an authorized result use `inspectPhoto`.
The callback contract explicitly prohibits publishing its provisional result itself.

A read is an observation at the validation boundary, not a filesystem transaction against
uncoordinated external writers or permission for a later mutation. Future writes still need
fresh admission and revision checks. The helper dependency integration and endpoint remain
open, as do production operation tools, FFmpeg Whisper and broader release gates. No native
client or acceptance gate is claimed complete.

## Verification

Only generated image and disposable directory fixtures; no user photos or preferences changed.
Host: arm64 macOS 27.0 (26A428), Debug test host.

Regression coverage checks the held photo lease during parsing, release after success and
parser failure, source/XMP/app-sidecar changes during parsing, newly created XMP/private
sidecars, ancestor replacement, revoked authorization, and the integrated generated-JPEG
read with effective fields and matching carrier revisions.

- Focused suite: **48 tests / 91 executions**, zero failures/skips,
  `build/qa-mcp-publication-focused-2.xcresult`.
- Final-source full suite: **2,994 tests / 3,888 executions**, zero failures/skips,
  `build/qa-mcp-publication-full.xcresult`, 154.544-second test operation.
  The four previously recorded QoS warnings remain in CaptionSessionTests and
  MetadataEditorReadServiceTests.
- Repository validation passes: `build/qa-mcp-publication-repository.log`.
- `git diff --check` passes.

The first sandbox test invocation could not write the standard compiler/package caches.
The approved retry passed. Reading the result summary also required test-report cache access.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  '-only-testing:Aagedal Photo Agent Tests/MCPMetadataSnapshotReaderTests' \
  -resultBundlePath build/qa-mcp-publication-focused-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-publication-full.xcresult -quiet

scripts/ci/validate_repository.sh
git diff --check
```
