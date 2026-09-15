# Cycle 38 — variable-write cross-process admission

**State:** IMPLEMENTING for 3.0. Variable/template metadata completion now owns one shared photo
lease from its first JSON preparation through physical write and semantic read-back. Production MCP
workflow tools, full GUI/MCP coordination and FFmpeg Whisper remain open.

## Change and boundary

- `VariableMetadataWriteService` acquires the extension-independent photo/folder lease before any
  retry verification or JSON history preparation. A busy peer returns a failure with the immutable
  request still available to retry and does not change the source, XMP or app sidecar.
- Nested `PendingMetadataWriteService` completion reuses that held lease instead of attempting a
  second lock. Direct Write All still acquires its own lease. A supplied lease must be active and
  cover the exact photo; a folder or another photo's lease cannot stand in for it.
- The existing in-process metadata coordinator, source/XMP/JSON revision checks, physical receipts
  and recovery rules remain the write authority. This expands one retained GUI write path and does
  not assert that face scan, rename or every other GUI operation is coordinated with MCP.

## Verification

- Source baseline: `b4bb86b7161258c7b01c0831b957f8abff87d3c7` on `main`, with only this cycle's
  source, test and documentation changes dirty during verification. Host: macOS 27.0, arm64.
- Focused Xcode command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
  'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
  -parallel-testing-enabled NO -jobs 1` with `-only-testing:` selectors for
  `MCPServerCoreTests`, `PendingMetadataWriteServiceTests` and `VariableMetadataWriteServiceTests`.
  **37 tests in 3 suites pass**. The new two-mode busy-lease case
  proves exact source/JSON preservation before preparation and retry success after lease release.
  Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.15_11-38-47-+0200.xcresult` in Xcode
  Derived Data. The app under test remains development version 3.0.0, build 738.
- `scripts/ci/validate_repository.sh` and `git diff --check` pass. The first sandboxed Xcode
  attempt could not write SwiftPM and Clang caches outside the workspace; the normal Xcode-cache
  attempt reached and passed assertions. That initial environment error is not a product failure.
- The complete serial suite passes **2,919 tests in 315 suites**, zero failures, in 121.879 seconds
  against the same app source. Result bundle:
  `Test-Aagedal Photo Agent Tests-2026.09.15_11-42-16-+0200.xcresult` in Xcode Derived Data.
  No native UI or real MCP client workflow is claimed for this internal coordination change.

## Beta and final-release distance

The four authoritative plans currently contain **81 unchecked criteria**: 9 improvement-audit,
23 investigation-delivery, 43 journalistic-metadata and 6 solar. Phase 5A alone has 26 unchecked
criteria. Counts describe scope rather than equal-sized tasks or a release calendar.

Beta remains several feature milestones away. It needs the shared production MCP facade and
revision-bound metadata/status/mutation workflows, coordination across the remaining GUI paths,
the reproducible FFmpeg build with embedded Whisper and model lifecycle, and a passing real-client
and current-source/native fixture drill. This cycle reduces an overlap risk but does not expose a
production MCP workflow.

Final release adds the broader investigation, metadata and solar manual gates; authentic Sony,
physical-volume, cloud, external-server and interoperability evidence; accessibility/performance on
supported hardware; qualified privacy/legal review and protected remote CI; independent candidate
review, exact-candidate user acceptance, and separately authorized signing/notarization and
distribution. The present evidence cannot support a responsible calendar date.
