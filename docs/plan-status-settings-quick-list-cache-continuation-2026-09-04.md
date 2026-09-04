# Plan-status Settings Quick List cache continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Settings and Metadata Quick List reads and mutations no
longer perform synchronous filesystem work from their MainActor view model or SwiftUI callbacks. The audit remains
at 66 of 75 completed substeps, with nine remaining.

## Serialized cache and durable mutation boundary

`KeywordListEditorPersistenceService` now owns the initial and replacement cache load for all eight Quick Lists.
It returns immutable complete, cancelled-before, exact cancelled-prefix, or cancelled-after-complete evidence,
including the exact list types whose reads failed. `SettingsViewModel` accepts only a complete result for the
current request and publishes a cache that makes SwiftUI entry and availability queries filesystem-free.

Committed-entry notifications install their payload directly. Notifications without a payload, including storage
routing changes, invalidate cached URLs before starting a replacement load so an old local or iCloud route cannot
remain authoritative. Replacement loads, teardown, and overlapping requests cancel and identity-gate publication;
partial evidence never replaces the last complete cache.

Import, append, replace, and delete operations now use the same actor. Every durable commit is published even when
cancellation is observed immediately afterward, while failed or cancelled-before-commit work is not presented as
successful. `KeywordListsStore.recordExternalDeletion` records an already-completed removal without repeating file
I/O. The Metadata panel and Expanded Face Management importer callbacks now await these operations instead of
calling synchronous persistence from SwiftUI.

A privacy-safe `OSSignposter` interval records only outcome state and aggregate requested, loaded, failed, and
committed counts. It never records a path, filename, list name, or entry text.

## Characterization and validation

Four new characterizations prove that a full cache load runs away from MainActor, cancellation returns the exact
completed prefix without publishing partial state, deletion returns durable evidence away from MainActor, and the
Settings/UI source contract remains cache-only and awaits actor-backed imports.

The focused `KeywordListEditorPersistenceServiceTests` suite passed all 15 tests. The adjacent keyword-list,
approved-list, analysis-export, and persistence-service selection passed all 30 tests across four suites. The
repository validation gate also passed.

The final serial unfiltered run passed all 1,954 tests in 227 suites with zero failures in 62.769 seconds. Result
bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.04_09-36-18-+0200.xcresult`.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
