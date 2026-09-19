# Cycle 49 — shared effective metadata resolution

**State:** IMPLEMENTING for 3.0. This extracts the production carrier-selection
policy for reuse by explicit-photo automation and fixes Copy Previous reads.
The bundled MCP helper still does not expose `get_photo_metadata`.

## Behavior

The editor reference selector and Caption Copy Previous now share the same pure
physical metadata resolver. Descriptive XMP records preserve explicit clears;
Develop-only XMP retains embedded descriptive values. A stale descriptive XMP
record leaves the newer embedded caption authoritative while retaining XMP
Develop settings. RAW Develop settings replace the embedded adjustment block,
with the existing local-mask fallback.

Pending app JSON overrides descriptive values while retaining physical orientation
and physical Develop settings (falling back to JSON Develop only when absent).
Saved JSON history does not override the physical record. Automatic resolution
also reports the descriptive carrier, pending state and XMP conflict separately.
The editor still honors the user's manual reference-source selection on reload.

Copy Previous now refuses an inconsistent XMP read instead of silently using
an incomplete embedded/JSON fallback. This applies even when pending JSON exists.
No file mutation, authority grant, or revision-token creation occurs in the resolver.
Parsing and coherent carrier capture remain the responsibility of its caller.

## Verification

Baseline: `8ca3f1d`; checkout initially clean. Source changes are the resolver,
its production editor/Copy Previous callers, and focused regression tests.
Host: arm64 MacBook Pro, macOS 27.0 (26A428).

- Focused suites: **66 tests / 108 parameterized executions, zero failures/skips**,
  `build/qa-effective-metadata-focused-20260919-2.xcresult`.
- Repository validation passed (`build/qa-effective-metadata-repository-20260919.log`).
- Full serial suite: **2,969 tests / 3,821 parameterized executions, zero failures/skips**,
  `build/qa-effective-metadata-full-20260919.xcresult`; Xcode test operation 139.326 seconds.

The initial focused build caught a missing writer dependency in the new Copy Previous
fixture, corrected before the passing run. Xcode reported the previously observed
exit-code-zero/no-output compile diagnostics and two runtime QoS warnings in the
metadata editor test file; neither produced a test failure. No claim of resolving
those warnings is made. The full run also reports two QoS warnings in CaptionSessionTests.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/SidecarReconciliationTests' \
  '-only-testing:Aagedal Photo Agent Tests/MetadataEditorReadServiceTests' \
  -resultBundlePath build/qa-effective-metadata-focused-20260919-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-effective-metadata-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
```

## Remaining work

Connect the shared resolver and production typed parsing to the MCP helper's
bounded, coherent carrier capture; preserve exact-byte revision association and
bounded output. Implement the remaining workflow tools, operation coordination,
FFmpeg Whisper and release validation. No Phase 5A checkbox is closed by this
shared policy extraction, and no new native UI evidence is claimed.
