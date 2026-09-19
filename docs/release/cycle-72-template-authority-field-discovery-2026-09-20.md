# Cycle 72 — Template store boundaries and MCP field discovery

Baseline: `85a6ff8`, clean at start. This cycle uses three implementation/review sub-agents;
the coordinator owns integration, Xcode execution, native testing and the commit.

## Implemented

Metadata and Develop inventories now carry their captured canonical storage folder. Existing
editors retain that original folder independently of later reloads. Saves and deletion compare
it under storage admission before reading or mutating another store. A folder change refuses;
Save as New explicitly saves an independent UUID into the current store. Missing inventory
provenance refuses an existing-template edit. Import success, partial failure and post-write
cancellation return the root with their inventory instead of performing an extra UI reload.

Deletion also compares the selected typed snapshot against exactly one current matching UUID
before Trash access. Changed, removed, corrupt and duplicate records refuse. The refreshed
list supports a deliberate fresh selection. Independent review found and fixed an error-path
bug where root mismatch could bless the new root without reading it; retry-before-reload
regressions now preserve both stores.

Develop templates now encode schema version 1. Unversioned records retain identity, settings,
shortcut and crop behavior. Newer, malformed or unreadable existing records refuse both decode
and compatibility overwrite, preserving exact original bytes. This does not claim preservation
of unknown members in a supported schema or atomicity against noncooperating external writers.

The bundled MCP helper exposes read-only `list_metadata_fields`: 43 stable editorial JSON keys,
scalar/list/structured schemas, absence semantics and shared parser limits. These IDs describe
existing read payloads; they are not editor-control IDs or write authorization. Structured
schemas share the reader's definitions. Discovery contains no photo values, works without
enabling automation and explicitly reports no mutation operations.

## Automated verification

The first sandboxed build could not write normal Xcode/Swift caches. Approved Xcode execution
built the focused source and ran 82 tests across five suites; one existing source-contract test
rejected the added post-import reload. The implementation was corrected to propagate captured
root evidence directly, and a partial-import failure regression was added.

The final integrated suite passes **3,040 tests across 321 suites**, zero failures and zero
skips, in 121.946 seconds. Xcode's result summary confirms 3,040 tests and records 4,022
parameter-expanded executions on this device. Repository validation and `git diff --check`
pass. Twelve Thread Performance Checker log entries and existing `MDB_MAP_FULL` test-host
messages remain observations; this cycle does not claim to resolve them. Independent review
found no outstanding issue after the retry-provenance correction.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-v3-template-discovery-full.xcresult
scripts/ci/validate_repository.sh
git diff --check
```

The initial focused invocation added test selectors for `DevelopTemplateSchemaTests`,
`TemplateDeletionConflictTests`, `DevelopTemplateTests`, `MetadataTemplatePersistenceTests`
and `MCPServerCoreTests`. The final complete run covers these and the import correction.
Evidence logs/results use `build/qa-v3-template-discovery-*`.

A direct STDIO exchange with the built `Contents/MacOS/photo-agent-mcp` passed initialize,
tools/list and list_metadata_fields, returning all 43 fields with mutation tools unavailable.
Raw protocol evidence: `build/qa-v3-mcp-discovery-protocol.jsonl`. This is executable protocol
evidence, not a supported third-party client acceptance test.

## Native verification

Host: arm64 macOS 27.0 (26A428). App: Debug 3.0.0 build 739 at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Native checks used the focused build; the subsequent source correction changes import provenance
only and is covered by the final integrated run. No import UI pass is claimed.

Settings now honors the existing gated `--ui-testing --ui-test-template-root` seam for both
metadata and Develop editors. Normal launches retain their existing storage routing. Fixtures
were generated under ignored `build/qa-v3-template-ui` (Develop in its `Develop` subdirectory).
The actual test app was launched with that absolute root; no template folder preference,
automation authorization or user photo was changed.

Observed through native accessibility and screenshots:

1. Open Settings → Templates, edit `QA Metadata Original`, rename its draft, then change the
   fixture on disk to simulate a newer writer. Save refuses and retains the draft. The error
   exposes Retry Save and Save as New. Save as New closes the sheet and displays both records.
2. Repeat for `QA Develop Original`. The retained draft and newer original both remain visible.
3. Change the first Develop record again while its older list row remains visible. Move to Trash
   refuses, preserves the file, refreshes the row to its new name, and displays guidance to review
   the refreshed templates before deleting again.
4. Filesystem assertions confirm exact peer bytes survive both Save as New operations and stale
   deletion, with independent UUIDs for both recovered drafts.

The original General settings page was restored and the disposable test instance closed with
all drafts saved. Fixtures remain in the ignored build folder for reproduction. Spoken VoiceOver,
root-switch interaction and relaunch persistence were not exercised in this narrow native pass.
The row's Edit/Trash buttons appear merged in the accessibility tree; this pass used screenshot
coordinates for those controls and does not claim keyboard/VoiceOver acceptance.

## Remaining before final release

- Byte-level template authority, same-path directory identity replacement, unknown-field
  preservation and stable-UUID MCP template discovery/application; import preview conflict authority.
- Remaining GUI/MCP operation coordination, status/cancellation, face-scan and batch transcription
  tools, guarded two-phase IPTC mutation and real-client validation.
- Aagedal Media Converter FFmpeg with embedded Whisper, model distribution and offline lifecycle.
- Authentic Sony/archive/reassociation/delivery, external editor and server interoperability,
  cloud/recovery, supported-device performance and full native/accessibility/display/map evidence.
- Qualified privacy/legal review, remote CI enforcement, exact release-candidate packaging,
  independent readiness review, final user acceptance and separately authorized distribution.

State remains IMPLEMENTING; no broad release gate is closed by this cycle.
