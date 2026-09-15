# Cycle 41 — explicit-photo revision evidence

**State:** IMPLEMENTING for 3.0. This starts the shared automation facade with one read-only,
revision-bound inspection. It does not implement typed `get_photo_metadata` or a mutation tool.

## Behavior

- `inspect_photo_revision` requires one explicit absolute photo path under an unchanged,
  enabled Settings grant. It admits the same photo input extensions as Browser and refuses
  directories or unsupported files.
- The shared app/helper facade holds the cross-process photo lease over the complete read and
  reauthorizes the exact photo identity before returning. A busy GUI or MCP peer refuses the
  inspection rather than returning a possibly mixed carrier state.
- Source and adjacent XMP bytes are hashed in bounded chunks through no-follow file
  descriptors. Owned app JSON in the current and legacy naming generations is checked for
  exact `sourceFile` association and hashed without exposing its metadata or transcript values.
  Each present carrier token binds its content, device/inode, size and modification snapshot.
  Symlink, hard-link, special-file, swapped-file and unsafe private-directory cases refuse the
  read. Each present carrier is checked again after hashing. The response carries opaque
  source/app-sidecar/XMP tokens and carrier-presence flags.
- Tokens are evidence for later exact-read and patch preparation. They do not imply that a
  carrier parsed successfully or that every supported input format supports embedded IPTC
  writes. The complete typed field/source/pending/conflict contract remains open.
- The complete-suite review exposed one unrelated RAW archive cancellation case marked
  skipped because its fixture cancelled the test task itself. The fixture now runs archive
  work in a child task and cancels that operation, leaving the test task alive to check
  rollback and exact source/memo bytes.

## Verification

- Source baseline: `c6b18b1` on clean `main` before this cycle. Changed source, tests and
  documentation were validated in the working tree. Host: arm64 macOS 27.0, Xcode 27.0;
  development app 3.0.0 (738).
- Focused command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
  -parallel-testing-enabled NO -jobs 1 '-only-testing:Aagedal Photo Agent
  Tests/MCPServerCoreTests' -resultBundlePath
  build/qa-mcp-cycle41-focused-final.xcresult -quiet`. All **14 tests** pass against the
  final descriptor-based implementation.
  New cases prove independent source/XMP/JSON token changes, a changed source token after
  identical-byte file replacement, no private-value response, JSON-RPC delivery, busy-photo
  refusal, foreign current-JSON refusal and linked-XMP refusal. Final result:
  `build/qa-mcp-cycle41-focused-final.xcresult` (ignored).
- A separate direct STDIO smoke check launched the exact Debug app-bundled helper at
  `Contents/MacOS/photo-agent-mcp` with `initialize`, `notifications/initialized` and
  `tools/list`. It returned all five tools including `inspect_photo_revision`, emitted
  no STDERR bytes and required no Settings preference change. This is built-helper
  discovery evidence, not a real MCP-client workflow.
- The `RAWArchiveTransactionServiceTests` focused selection passes all **17 executions**,
  zero failures and zero skips after the cancellation-fixture repair. Result:
  `build/qa-mcp-cycle41-archive-cancellation.xcresult` (ignored).
- Repository validation and `git diff --check` pass after the source change. The final
  documentation-inclusive run passes generated documents, release metadata, tracked
  JSON/plist, component provenance, privacy scans and whitespace checks.
- Complete command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj'
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
  -parallel-testing-enabled NO -jobs 1 -resultBundlePath
  build/qa-mcp-cycle41-full-combined.xcresult -quiet`. The combined-source serial suite
  passes **3,767 Xcode test executions, zero failures and zero skips**; the test operation
  took 129.072 seconds. The preceding final-implementation run had one
  intentional-cancellation fixture skip; that skip motivated the repair above.

## Beta and final-release distance

Beta still needs the production metadata reader with typed descriptive values, effective
carrier/pending/conflict state and exact tokens; status/cancellation and guarded face,
template, transcription and two-phase IPTC workflows; complete GUI/MCP overlap refusal;
root-anchored carrier traversal and ancestor-retargeting race coverage;
the reproducible FFmpeg build with embedded Whisper and hardened model lifecycle; and
current-source real-client workflow checks. This cycle removes one read/evidence prerequisite
but does not close a complete Phase 5A feature gate.

Final release additionally needs broad exact-candidate native and physical-volume tests,
authentic Sony/cloud/server/interoperability evidence, accessibility and supported-hardware
performance, qualified Known People privacy/legal review, protected remote CI, independent
readiness review, user acceptance and separately authorized signing/notarization/distribution.
The remaining criteria vary enough that a defensible calendar date is not available yet.
