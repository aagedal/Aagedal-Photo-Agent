# Batch rename recipe library validation

**Validated:** 2026-08-21  
**Scope:** Phase 3 persisted presets and browser-sheet recipe management

## Implemented contract

- `BatchRenameRecipeRepository` stores a versioned atomic catalog with stable UUID identity,
  deterministic ordering, persisted selection, and version-one migration.
- Create, update, duplicate, rename, delete, import, and export reject ID/name collisions; export
  never overwrites an existing destination. A FIFO async gate spans each complete load/modify/save
  operation so actor reentrancy cannot lose overlapping mutations.
- Persistence validates recipe/schema versions, time zones, regular expressions, and the complete
  renderer contract before changing the catalog.
- The browser sheet exposes Ad Hoc plus saved presets and Save/Update/Duplicate/Rename/Import/
  Export/Delete actions. Selection loads automatically, switching preserves per-preset drafts, and
  deleting the active preset retains its current draft as Ad Hoc.
- Every preset or draft change rebuilds the immutable preview plan. Imported recipes retain the
  complete renderer semantics, including advanced tokens, substitutions, transforms, sanitation,
  Unicode mode, fallback, and missing-value policy, even when the compact editor has no direct
  control for a particular advanced option.

## Test evidence

```sh
xcodebuild build-for-testing \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-rename-recipe-library-build-01' \
  -jobs 2

xcodebuild test-without-building \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-rename-recipe-library-build-01' \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameRecipeRepositoryTests' \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameRecipeTests' \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameSheetStateTests'
```

Result: the final shared-worktree build-for-testing succeeded and **28 tests passed in 3 suites**,
including nine repository/editor tests and a deterministic overlapping-mutation regression.

## Remaining integration

- Add direct controls for the renderer's advanced substitutions/transforms and broader metadata,
  camera, job, and import token surface.
- Ad-hoc drafts intentionally last only for the open sheet unless saved.
- Import conflicts are rejected rather than merged; the catalog is local Application Support and
  is not cloud-synchronized.
