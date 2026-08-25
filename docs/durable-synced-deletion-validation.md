# Durable synced deletion validation

**Validated:** 2026-08-25  
**Scope:** audit plan 0.1 — Known People, Teams, and Watermarks

## Implementation evidence

- `DurableDeletionTransaction` is the single transaction boundary used by all three stores. It encodes the
  marker, writes it through `CloudCoordinatedIO`, reads and decodes the installed bytes, verifies the record
  identity, and only then removes the source record.
- Marker encode, write, read-back/decode, identity verification, source removal, and marker rollback failures
  are typed `DurableDeletionError` cases. User-facing descriptions are recovery-oriented and omit underlying
  error strings that could contain private paths or values.
- A failed read-back or source removal rolls the marker back so the still-present source remains usable. If
  rollback itself fails, the source remains on disk and the error documents the retry-to-finish recovery state.
- Known People delays person, feature-print, representative-thumbnail, and embedding-thumbnail cache cleanup
  until the transaction succeeds. Teams and Watermarks likewise mutate their observable libraries only after
  success.
- Known People merge writes the target first, then performs the durable source deletion. If the second step is
  interrupted, the source remains usable; retry is idempotent because embeddings are deduplicated by feature
  print bytes.
- The Known People list, expanded Known People merge/delete view, Teams library, and Watermarks library retain
  selection/state and present a recoverable failure instead of silently displaying success.

## Automated validation

The following focused commands succeeded on macOS:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/DurableDeletionTransactionTests' \
  -only-testing:'Aagedal Photo Agent Tests/KnownPeopleServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/RosterStoreTests' \
  -only-testing:'Aagedal Photo Agent Tests/WatermarkStoreTests'
```

The focused coverage proves:

- injected marker encode/write/read-back and record-remove failures preserve the original record;
- invalid marker identity is rejected and rolled back;
- rollback failure produces the documented retryable interrupted state without exposing its private diagnostic;
- marker-write failures preserve Known People thumbnails, team records, and complete watermark item folders;
- installed markers decode to the deleted record identity;
- stale peer records cannot resurrect successfully deleted people, teams, or watermarks; and
- an interrupted Known People merge retains its source and a retry completes without duplicate embeddings.

The focused run covered 23 logical tests across the four suites. It does not replace the repository's
full unfiltered release test gate.
