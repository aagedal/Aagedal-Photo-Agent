# Cycle 59 — Effective metadata tool in the bundled helper

State: IMPLEMENTING. Baseline `ca7ccdb`; checkout initially clean. Evidence below tests
that baseline plus this cycle's working-tree changes. Host: arm64 macOS 27.0, Debug.

## Implementation

The bundled `photo-agent-mcp` target now links SwiftMediaMetadata and the production typed
metadata models, dictionary adapter, XMP decoder and effective resolver. The resolver takes
captured values directly; the interactive editor retains a compatibility adapter for its read
facts. The shared ACR number formatter moves out of the write engine into metadata parsing.
No editor filesystem service or metadata write engine is added to the helper target.

`get_photo_metadata` accepts one explicit absolute `path`. It returns the bounded effective
editorial projection, per-field selection carrier, pending/conflict state and opaque source,
XMP and owned-JSON revisions. Parsing and output preparation remain inside the existing photo
reservation and anchored snapshot/publication checks. No file mutation or write authority is
introduced. Invalid arguments, disabled/revoked authority, busy photos and unsafe carriers use
existing typed refusals; other parsing/output failures return a stable `metadata_read_failed`
without parser diagnostics or partial values. Discovery and capability reporting advertise the
new tool with read-only annotations.

README, help, Settings disclosures, limitations and changelog describe the current boundary.
The draft manual checklist adds A21 for real-client effective-read and revocation validation;
all human outcomes remain unrun.

## Verification

Disposable generated JPEGs, literal XMP and app JSON only; no user photos or preferences changed.
Protocol tests cover typed values/provenance/revisions, disabled authority, unknown/missing/wrong-
type arguments, busy reservations, malformed source/XMP and oversized records. They verify
unchanged source/sidecar bytes and released reservations after success or refusal. Existing
snapshot/resolver tests cover pending/saved drafts, clears, conflicts and publication races.

- Focused suite: **51 tests / 103 executions**, zero failures/skips,
  `build/qa-mcp-endpoint-focused-4.xcresult`; 4.863-second test operation.
- Final-source complete serial suite: **2,997 tests / 3,900 executions**, zero failures/skips,
  `build/qa-mcp-endpoint-full.xcresult`; 130.164-second test operation. The same four
  previously recorded QoS warnings remain in CaptionSessionTests and MetadataEditorReadServiceTests.
- Repository validation passes: `build/qa-mcp-endpoint-repository.log`.
- Actual helper executable STDIO smoke passes initialize, seven-tool discovery, implemented
  capability reporting and invalid-argument refusal, with empty stderr and exit zero. Record:
  `build/qa-mcp-endpoint-stdio.json` (standalone build product) and
  `build/qa-mcp-endpoint-bundled-stdio.json` (actual signed-on-copy embedded helper); both
  include exact executable path and SHA-256. The app is 3.0.0 build 739 at
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
  No new native GUI or production-client evidence is claimed.
- Checklist JSON validates with unique case IDs; `git diff --check` passes.

The initial sandbox build could not write the normal compiler/package caches; approved Xcode
invocations use them. An initial direct-target build did not resolve the package import;
validation uses the app test scheme's complete dependency graph. Subsequent compiler diagnostics
identified missing shared model membership and the formatter's write-engine placement; both
were corrected before the passing validation. The passing focused build also emitted transient
compiler-driver “exit code 0 but produced no further output” diagnostics; the subsequent full
run completed without those diagnostics. Generated standalone-build cache files were moved
under ignored `build/`.

## Remaining release work

This closes helper integration and the single-photo effective metadata endpoint implementation,
not the broader Phase 5A or release-readiness gates. Real-client launch/read/revocation evidence
for Codex CLI, Claude Code and both OpenCode versions remains open. Template/provider discovery,
face scan, metadata/Develop template application, batch transcription, shared operation
status/cancellation, remaining GUI operation admission and two-phase IPTC patches remain.
FFmpeg/Whisper integration, authentic/offline/VoiceOver/cloud/delivery evidence, performance and
hardware coverage, external-editor round trips, legal/remote CI dependencies and final candidate
packaging/user acceptance remain tracked in `readiness.md` and `gate-inventory.md`.

## Commands

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPMetadataSnapshotReaderTests' \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  '-only-testing:Aagedal Photo Agent Tests/XMPMetadataReaderTests' \
  -resultBundlePath build/qa-mcp-endpoint-focused-4.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-endpoint-full.xcresult -quiet

scripts/ci/validate_repository.sh
git diff --check
```
