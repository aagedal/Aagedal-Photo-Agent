# Cycle 40 — MCP format discovery and call contract

**State:** IMPLEMENTING for 3.0. This completes a bounded read-only discovery slice and
tightens the existing local MCP call boundary. The production facade, metadata reads,
operation lifecycle, mutations and Whisper remain open.

## Behavior

- `list_supported_photo_formats` reports the same input-extension sets as Browser admission,
  with RAW extensions identified separately. It explicitly describes embedded IPTC write
  support as format and carrier dependent. Its read-only, non-destructive, idempotent and
  closed-world annotations match the existing foundation tools.
- `get_server_capabilities` advertises the new input-format discovery boundary without
  advertising a production mutation tool. Automation remains default-off, and format
  discovery does not expose private path or metadata values.
- Unknown tool names, empty names and non-object `arguments` now return JSON-RPC invalid
  parameters. Extra properties on a known tool return a bounded tool execution error,
  so a client can correct its arguments. The tool's own filesystem authority still
  decides whether an otherwise valid explicit path can be read.

## Verification

- Source baseline: `5a8b0f3f9163b608d117e52613f01af4a258858f` on `main`, with this
  cycle's source, tests and documentation dirty during verification. Host: arm64 macOS
  27.0 (26A428), Xcode 27.0 (27A266a), development app 3.0.0 (738).
- Focused command: `xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme
  'Aagedal Photo Agent Tests' -configuration Debug -destination 'platform=macOS'
  -parallel-testing-enabled NO -jobs 1 '-only-testing:Aagedal Photo Agent
  Tests/MCPServerCoreTests' -quiet`. It passes on the changed source after correcting
  a Set construction error found by its first compile. The tests compare discovery
  to GUI admission and check tool-call structure, unknown names and extra-property errors.
- Repository validation passes generated documents, release metadata, tracked JSON/plist,
  bundled-component provenance, privacy scans and whitespace checks after the documentation
  update. Final log: `build/qa-mcp-cycle40/repository-validation-final.log` (ignored).
- A sandboxed complete-suite attempt stopped before compilation because Xcode could not
  write its normal SwiftPM and Clang module caches outside the writable roots. The standard
  cache command runs the same project/scheme/configuration/destination serially with
  `-resultBundlePath build/qa-mcp-cycle40/full-standard-cache.xcresult -quiet` and no
  `-only-testing` filter. It passes **2,922 tests**, zero failures, with Xcode's
  complete test operation taking 132.514 seconds. Result:
  `build/qa-mcp-cycle40/full-standard-cache.xcresult` (ignored). Xcode reports four
  existing QoS priority-inversion runtime warnings in adjacent Caption/metadata tests;
  this slice does not claim to close those performance observations.

## Beta and final-release distance

Beta remains feature implementation work: a production MCP facade with revision-bound
metadata reads, operations/status/cancellation and guarded writes; comprehensive shared
GUI/MCP coordination; the reproducible FFmpeg build containing Whisper and its hardened
model lifecycle; and current-source real-client workflow checks. This cycle closes only
one discovery/tool-call slice.

Final release additionally needs the exact candidate's broad native, physical-volume,
cloud, authentic Sony, real-server, interoperability, accessibility and performance
evidence; qualified Known People privacy/legal review; protected remote CI; independent
candidate review; user acceptance; and separately authorized signing, notarization and
distribution. The open criteria vary substantially in size, so a calendar date is not
supported by the present evidence.
