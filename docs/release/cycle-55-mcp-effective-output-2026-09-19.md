# Cycle 55 — Bounded effective metadata output

State: IMPLEMENTING. Baseline `f54de89`, initially clean checkout.

The typed immutable snapshot reader now projects its resolved editorial metadata into a
bounded protocol value. The target identity stays with the parsed result, alongside all
three captured revision tokens. The output reports pending changes, XMP conflict and the
selected descriptive record. This carrier label deliberately does not claim per-field
provenance: localized Titles, capture date, GPS, rating and label can inherit embedded
values under the production resolver's rules.

The projection reuses the strict editorial catalog already used by owned-draft inspection.
Its explicit allowlist excludes Develop/orientation and private sidecar history. Absent
scalar values are explicit nulls, while empty strings and arrays retain their clear semantics.
Headline and localized Titles remain distinct, creators and supplier pairs retain order,
and numbers remain typed. Text remains literal untrusted data.

Limits are shared with draft inspection: 32,768 UTF-8 bytes per scalar, 128 items per array,
1,024 bytes per string-list item and 65,536 aggregate text bytes. Structured records retain
the existing catalog's bounds. A final 262,144-byte serialized-value check also accounts for
JSON escaping and response metadata. Any failure refuses the whole result without truncation.

This remains an internal app-side projection. The bundled helper does not yet expose
`get_photo_metadata`. Helper dependency wiring, authorization revalidation at publication,
field-level provenance and real-client verification remain open. Captured revisions do not
grant write authority. No release-readiness or Phase 5A acceptance checkbox closes.

## Verification

Tests use generated four-by-two JPEGs and in-memory editorial records; no user photos or
preferences are modified. Coverage includes captured target/revision association, embedded
versus XMP selection, pending/saved JSON, null versus explicit clear, localized Titles,
ordered creators/suppliers, structured locations/contact data, technical-field exclusion,
UTF-8 and aggregate limits, JSON escape expansion and non-finite number refusal.

Host: arm64 MacBook Pro, macOS 27.0 (26A428), Debug test-host build.

- Focused validation: **44 tests / 79 executions**, zero failures/skips;
  `build/qa-mcp-output-20260919-2.xcresult`.
- Full final-source serial regression: **2,988 tests / 3,873 executions**, zero failures/skips;
  `build/qa-mcp-output-full-20260919.xcresult`, 157.326-second test operation. The four
  previously recorded QoS warnings remain in CaptionSessionTests and MetadataEditorReadServiceTests.
- Repository validation passes; `build/qa-mcp-output-repository-20260919.log`.
- `git diff --check` passes.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  '-only-testing:Aagedal Photo Agent Tests/MCPMetadataSnapshotReaderTests' \
  '-only-testing:Aagedal Photo Agent Tests/MCPServerCoreTests' \
  -resultBundlePath build/qa-mcp-output-20260919-2.xcresult -quiet

xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 1 \
  -resultBundlePath build/qa-mcp-output-full-20260919.xcresult -quiet

scripts/ci/validate_repository.sh
git diff --check
```

The first sandbox invocation lacked compiler-cache access; the approved retry uses the
normal Xcode caches. No native UI changed and no native-client acceptance is claimed.

Xcode emitted the previously observed exit-code-zero/no-output diagnostics during the focused
compile, but completed successfully. The subsequent complete suite passed.
