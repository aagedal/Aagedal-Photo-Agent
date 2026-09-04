# Plan-status Settings structured-keyword import continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Both Settings file pickers for Structured Keywords and
Structured Person Shown now move user-selected source access and managed-file persistence through serialized actors
instead of performing those operations synchronously on MainActor. The audit remains at 66 of 75 completed
substeps, with nine remaining.

## Serialized source and commit boundaries

`TextFileImportService` now acquires and balances security-scoped access on its actor before reading a selected text
file. Access acquisition, the synchronous byte read, and release therefore stay on the same non-main executor.
Cancellation is sampled before and after the non-preemptible acquisition and read calls, while an unavailable
optional security-scope claim preserves the previous permissive behavior.

`StructuredKeywordService` parses the immutable text snapshot, rejects empty files before persistence, and sends
the original tab-indented text to `KeywordListEditorPersistenceService`. Its new text commit preserves hierarchy
without converting the file into a flat list and reports whether cancellation was observed before or after the
durable coordinated write.

Each Settings picker owns a cancellable task and request identity. A replacement import invalidates the older
request before it can commit a completed read, view disappearance cancels both picker tasks, and only the current
request can publish an error. After a durable commit, `KeywordListsStore` broadcasts the committed text in memory;
structured-list observers install that snapshot rather than synchronously re-reading the managed file on MainActor.

## Characterization and validation

Five new characterizations prove that:

- selected-file security-scope acquisition and balanced release run on the filesystem actor;
- a structured-text commit preserves tab-indented hierarchy and returns durable off-main evidence;
- the Settings import path reads and commits away from MainActor while updating the structured model;
- a replacement import prevents an older completed read from committing; and
- both Settings pickers own cancellable async imports and invalidate their services.

Validation completed with:

- the focused structured-keyword/text-import/persistence selection: 32 tests in 3 suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,018 tests in 232 suites passed in 61.413 seconds with zero
  failures.

The full-run result bundle is `Test-Aagedal Photo Agent Tests-2026.09.04_23-24-00-+0200.xcresult` in Xcode
DerivedData. Automated evidence is complete for this bounded continuation, while the remaining manual and
real-volume gates below are deliberately not claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
