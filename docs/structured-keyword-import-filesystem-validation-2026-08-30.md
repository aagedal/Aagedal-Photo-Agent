# Structured Keyword import filesystem validation — 2026-08-30

## Scope

This Phase 3.1 slice moves the user-selected structured-keyword file read out of
`StructuredKeywordEditor`'s MainActor UI action. It intentionally does not claim completion of the broader
filesystem inventory, slow-volume signpost/benchmark, or Thread Performance Checker gates.

## Implemented boundary

- `TextFileImportService` is a serialized actor around the synchronous Foundation `Data(contentsOf:)` read.
- The actor returns an immutable, sendable snapshot only after the complete file has been read and decoded.
- Cancellation before the reader is entered performs no filesystem work. Cancellation observed after the
  non-preemptible read returns byte-count evidence but never publishes partial or complete text to the UI.
- `StructuredKeywordEditor` owns one import task and request identity, cancels superseded/disappearing work,
  and rejects late results before replacing the editable tree.
- Existing UTF-8, UTF-16, and ISO Latin-1 decoding behavior and the review-before-Save workflow are preserved.

## Automated characterization

Focused suite: `TextFileImportServiceTests` in
`Aagedal Photo Agent Tests/AnalysisExportFileServiceTests.swift`.

The five tests cover:

1. a complete immutable snapshot and an injected proof that the synchronous reader did not run on the main
   thread;
2. pre-cancellation with zero reader invocations;
3. actor serialization plus cancellation of a queued read;
4. explicit cancellation-after-read evidence with no text payload; and
5. the view source contract: awaited service use, request-identity guard, explicit cancellation handling,
   and removal of direct `Data(contentsOf:)` from the import action.

## Validation result

The app and test targets compiled and the focused suite passed: **5 tests in 1 suite, 0 failures**. The run
used isolated DerivedData because other concurrent audit slices were building the shared workspace:

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-text-import-derived-data' \
  -only-testing:'Aagedal Photo Agent Tests/TextFileImportServiceTests'
```

## Manual follow-up

Before release-candidate integration, import representative UTF-8, UTF-16, and Latin-1 structured-keyword
files from a slow external/network volume; close the editor and begin a second import while a read is in
flight; verify no stale tree replacement and no Thread Performance Checker main-thread filesystem warning.
