# Keyword-list backup preview filesystem validation — 2026-08-30

## Scope

This Phase 3.1 slice moves the backup preview's synchronous text read out of
`KeywordListBackupsSheet`'s MainActor SwiftUI rendering path. It intentionally does not claim
completion of the broader `KeywordListsBackupService` filesystem migration: history enumeration,
snapshot/prune work, recovery detection, and restore reads remain follow-up inventory items.

## Implemented boundary

- `KeywordListBackupPreviewService` is a serialized actor around the synchronous Foundation
  `Data(contentsOf:options:)` read and UTF-8 decode.
- The actor returns a complete immutable snapshot containing request identity, source identity,
  decoded text, and byte count.
- Cancellation before the reader is entered performs no filesystem work. Cancellation observed
  after the non-preemptible read returns source and byte-count evidence without exposing text to
  the caller.
- `KeywordListBackupsSheet` owns one preview task and request identity. A replacement preview,
  list-selection change, history reload, or sheet dismissal cancels the prior task and clears its
  presentation state.
- Completion is accepted only when both the request identity and version URL still match, so a
  delayed read cannot replace a newer preview.
- Loading and read/decode failures now have explicit presentation states instead of synchronously
  blocking the view and silently rendering an empty string.

## Automated characterization

Focused suite: `KeywordListBackupPreviewServiceTests` in
`Aagedal Photo Agent Tests/KeywordListsStoreTests.swift`.

The five tests cover:

1. a complete immutable snapshot and proof that the injected synchronous reader did not execute
   on the main thread;
2. pre-cancellation with zero reader invocations;
3. actor serialization plus cancellation of a queued preview;
4. cancellation-after-read evidence with no text payload; and
5. the sheet source contract: awaited service use, request/version identity guards, dismissal
   cancellation, and removal of its direct `String(contentsOf:)` preview read.

## Validation result

The production app target built successfully. The focused suite passed: **5 tests in 1 suite,
0 failures**.

```sh
xcodebuild build \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-keyword-preview-derived-data'

xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-keyword-preview-derived-data' \
  -only-testing:'Aagedal Photo Agent Tests/KeywordListBackupPreviewServiceTests'
```

## Follow-up

- Move `allVersionsByKey()`/`versions(for:)` enumeration and content counting off MainActor before
  treating the backup browser as fully migrated.
- Characterize and migrate the synchronous restore read and the snapshot/prune lifecycle without
  weakening their current backup-before-restore and retention invariants.
- Manually preview backups on a deliberately slow or externally mounted Application Support
  volume, rapidly switch versions, change list selection, and dismiss the sheet; verify that the
  UI remains responsive, stale text never appears, and Thread Performance Checker reports no
  preview-read warning.
