# Batch rename planning validation

**Validated:** 2026-08-21  
**Scope:** Phase 3 pure planning, collision policy, artifact discovery, and reservations

## Implemented contract

- Input order is preserved and is the only order used to allocate sequence tokens and preview
  rows.
- Each immutable plan entry retains source, requested destination, accepted destination,
  disposition, recipe evaluation, artifact actions, and structured issues.
- The standard artifact registry covers the image, adjacent XMP, and current/legacy
  `.photo_metadata` JSON sidecars; callers can register further filename-derived artifacts.
- Planning consumes an injected snapshot of existing paths and explicit filesystem case
  sensitivity, without reading or mutating the filesystem.
- The default block policy, skip policy, and deterministic suffix policy account for the whole
  artifact bundle before reserving a destination.
- Two-way swaps and longer cycles are accepted when every participating source will move. A
  fixed-point dependency audit blocks a target again if a putative mover is skipped or blocked.
- The plan exposes every reserved image/artifact destination and a compact associated-artifact
  summary for a future preview sheet and executor.

## Test evidence

The focused suite covers visible ordering, standard and custom artifacts, all missing-value
outcomes, invalid names, duplicates, existing targets, suffix allocation, artifact collisions,
case-sensitive and case-insensitive behavior, bounded suffix exhaustion, two-way and three-way
cycles, and a skipped-mover dependency regression.

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-rename-planning-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/RenamePlanningServiceTests'
```

Result: **13 tests passed**. The pure recipe/planner sources also pass strict-concurrency
type-checking.

## Remaining integration

- Build the resizable preset/component editor and render the complete plan as a preview table.
- Expand the registry to face data, analysis/project references, and cache invalidation hooks.
- Implement permission preflight and a two-phase `RenameExecutionService` with temporary paths,
  rollback reporting, safe cancellation boundaries, and post-rename in-memory reassociation.
