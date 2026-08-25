# Sidecar transaction serialization validation

**Validated:** 2026-08-25  
**Scope:** Phase 0.4 URL-keyed XMP and metadata-history sidecar transactions

## Implemented boundary

- `MetadataIOCoordinator` remains the single URL-keyed actor. XMP descriptive and Develop entry
  points now acquire the same extension-independent photo key for the complete
  read/merge/validate/install/read-back operation.
- XMP transactions retain the exact source bytes as their content token, yield before install,
  compare the current bytes with that token, and restart the merge up to four times when an
  external editor replaced the document.
- XMP staging is parsed before install. Installation remains atomic and the installed bytes are
  read back byte-for-byte and parsed again before success is reported.
- Metadata JSON history transactions compare both current and legacy candidate bytes before
  install. New field history entries are replayed onto the latest record, histories are
  de-duplicated and ordered by timestamp plus stable entry identity, and the installed schema is
  decoded and compared before success.
- Existing JSON schema refusal, unknown-field preservation, corrupt-file recovery backup, and
  atomic replacement behavior remain active because the transaction delegates installation to
  `MetadataSidecarService.saveSidecar`.

## Routed workflows

The serialized boundary is used by the descriptive metadata write boundary, Caption's durable
FIFO queue, the Metadata panel's single-image XMP/history commit, face-name sidecar persistence,
and Develop-version promotion. A few older synchronous Metadata batch/reset helpers still call the
legacy service methods, so the audit substep requiring every Caption, Metadata, face, and Develop
write to use the boundary remains open.

## Automated validation

Targeted command:

```text
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveMetadataWriteBoundaryTests'
```

Result: **9 tests passed**. This includes a deterministic revision test that replaces XMP exactly
between staging and the token check and proves the merge restarts from the replacement, a
40-iteration stress test that starts Caption,
face-name, and Develop writes together against one XMP sidecar and verifies the headline, person,
and Camera Raw exposure all survive, plus a JSON test that starts two stale history documents
together and verifies both fields and deterministic history order.

Regression command:

```text
xcodebuild test-without-building -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionSessionTests' \
  -only-testing:'Aagedal Photo Agent Tests/ApplicationTerminationFlushCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataSidecarServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopVersionCatalogTests'
```

Result: **65 tests passed across 4 suites**.

The Xcode run emitted pre-existing App Intents extraction and LMDB map-size diagnostics; neither
was a test failure. No project-file edit was needed for this work.
