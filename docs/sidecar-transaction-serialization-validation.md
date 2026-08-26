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
- Intentional JSON history replacements (currently Clear History) use the same revision check and
  read-back verification, retaining the latest metadata record without replaying the history that
  the user explicitly cleared.
- Destructive XMP stripping is also serialized. It retries against the exact source bytes,
  preserves Develop settings when present, validates a rewritten document before and after
  install, and verifies deletion when no Develop block remains.
- Existing JSON schema refusal, unknown-field preservation, corrupt-file recovery backup, and
  atomic replacement behavior remain active because the transaction delegates installation to
  `MetadataSidecarService.saveSidecar`.

## Routed workflows

The serialized boundary is used by the descriptive metadata write boundary, Caption's durable
FIFO queue, face-name sidecar persistence, and Develop-version promotion. The remaining Metadata
panel and browser workflows now use it as well: single and batch drafts, embedded-state mirroring,
variable processing, rating/label edits, metadata review, history clear/restore, Develop reset,
and XMP IPTC removal. The older synchronous service functions remain available for isolated
fixtures and migration/copy operations, but no Caption, Metadata, face, or Develop mutation calls
them.

## Automated validation

Targeted command:

```text
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveMetadataWriteBoundaryTests'
```

Result: **11 tests passed**. This includes a deterministic revision test that replaces XMP exactly
between staging and the token check and proves the merge restarts from the replacement, a
40-iteration stress test that starts Caption,
face-name, and Develop writes together against one XMP sidecar and verifies the headline, person,
and Camera Raw exposure all survive, plus JSON tests for stale-history merging and explicit
history replacement and an XMP strip test proving Develop settings survive.

Regression command:

```text
xcodebuild test-without-building -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/DescriptiveMetadataWriteBoundaryTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataBatchSelectionTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionSessionTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataSidecarServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopVersionCatalogTests'
```

Result: **72 tests passed across 5 suites**. A fresh `build-for-testing` also succeeded before the
focused run.

The Xcode run emitted pre-existing App Intents extraction and LMDB map-size diagnostics; neither
was a test failure. No project-file edit was needed for this work.
