# Batch rename browser integration validation

**Validated:** 2026-08-21  
**Scope:** Phase 3 shared single/batch planning sheet, transactional execution, and browser-state projection

## Implemented contract

- Existing single-file and batch image rename commands now open one resizable SwiftUI sheet; the
  former image `NSAlert` and direct `FileManager` mutation paths are removed. Folder rename remains
  a separate operation.
- The editor supports literal, original filename/stem/extension, sequence, capture-date, file-
  creation-date, and file-modification-date components plus block, skip, and deterministic-suffix
  collision policies.
- Planning receives selected images in authoritative visible browser sort order and a frozen
  filesystem/case-sensitivity snapshot. The sheet presents a live sample and complete old,
  requested, and planned filename table.
- Typed per-row issue text exposes missing data, invalid names, occupied/duplicate destinations,
  case-only behavior, and applied suffixes. Aggregate badges and associated-artifact summaries do
  not replace the row-level explanation.
- Rename is enabled only for the exact executable immutable plan and runs asynchronously only
  through `RenameExecutionService`.
- A successful result projects the complete mapping at once, so cycles preserve selected URLs,
  last-click, and manual order without transient duplicate keys. Old and new technical metadata,
  thumbnail, full-screen, edited-preview, and C2PA validation cache keys are invalidated.
- Failure/cancellation publishes typed execution issues and residual paths, invalidates the stale
  plan, and reloads authoritative folder state. A fresh preview is allowed only after a proven
  clean rollback with no residuals; incomplete rollback requires closing and reselecting from the
  reloaded browser.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-batch-rename-ui-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameRecipeTests' \
  -only-testing:'Aagedal Photo Agent Tests/RenamePlanningServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/RenameExecutionServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameSheetStateTests'
```

Result: **44 tests passed in 4 suites**, and the full application/test targets compiled.

## Remaining integration

- Add recipe repository, preset selection, save/duplicate/rename, and import/export UI.
- Expose the renderer's richer substitutions, transforms, metadata, and camera tokens in the
  component editor.
- Face, named Develop, comparison, and analysis reassociation is complete; see
  [the reassociation validation record](batch-rename-reassociation-validation.md). Add the remaining
  face-scanner pause/flush contract and route future path-keyed records through the same boundary.
- Add optional original-filename metadata at a standards-defined and explicitly tested
  transaction point.
