# Batch rename reassociation validation

**Validated:** 2026-08-21  
**Scope:** Phase 3 persisted and live app associations after transactional filesystem rename

## Implemented contract

- The rename executor continues to move RAW/JPEG files, XMP sidecars, metadata JSON, and registered
  filename-keyed artifacts as one staged bundle. A named-Develop flush barrier runs before the
  filesystem transaction.
- Before filesystem execution, an injected quiescence barrier reserves the target folder, cancels
  and awaits the exact active face scan through its final persistence, drains lens-prewarm and face
  metadata writers, and closes an Analysis save gate after awaiting existing load/case/folder-map
  work. A typed barrier failure prevents every filesystem move.
- After successful filesystem execution, `RenameReassociationService` simultaneously remaps folder
  face records, number detections, absolute scanned-file keys, and folder-local analysis source
  hints. Face IDs, embeddings/groups, analysis UUIDs, hashes, evidence, and timestamps are retained.
- Persisted face and analysis failures are typed and visible. The completed immutable plan remains
  disabled and the browser reloads the folder authoritatively; a successful filesystem rename is
  never silently retried.
- Develop catalogs are deliberately not path-rewritten because they are keyed by source-content
  identity. A real RAW/XMP cycle proves that distinct Develop settings and named versions reopen
  with the correct renamed source bytes.
- Live comparison, Clean Feed, and analysis state receive the complete mapping simultaneously, so
  cycles preserve representations, focus, layout, viewports, alignment/lock/wipe state, open case
  identity, and source hashes.
- Rename mapping and available-image reconciliation are one coordinator transition, so SwiftUI
  observation order cannot clear an old comparison source before its renamed URL is applied.
- Persistent and live face, analysis, and comparison lookups share a symlink-resolving canonical
  URL key, matching the canonical source-revision identity captured by the app.
- Browser projection now includes pending-metadata, last-refresh-modified, and dragged URLs in
  addition to images, selection, last-click, manual order, and old/new cache invalidation.
- The Analysis gate stays closed across execution: success maps live state and drains late changes
  under destination hints; a pre-move Develop refusal drains under the original hint; executor
  failure cancels producers and closes unsafe live Analysis state. Target face scans cannot restart
  until the reservation is released.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-rename-reassociation-tests-01' \
  -clonedSourcePackagesDirPath '/private/tmp/aagedal-batch-rename-derived/SourcePackages' \
  -disableAutomaticPackageResolution -jobs 4 \
  -only-testing:'Aagedal Photo Agent Tests/BatchRenameSheetStateTests' \
  -only-testing:'Aagedal Photo Agent Tests/ComparisonCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/DevelopVersionCatalogTests' \
  -only-testing:'Aagedal Photo Agent Tests/RenameExecutionServiceTests'
```

Result: **65 tests passed in 4 suites**. After final state/cache changes, the two directly affected
suites were rerun: **35 tests passed in 2 suites**. Both runs compiled the app/test graph and
reported `TEST SUCCEEDED`; `git diff --check` also passed.

An independent race/canonicalization regression run subsequently passed **51 tests in 4 suites**,
including rename-before-availability ordering and symlinked-folder persistence/live-state cases.

The final writer-barrier run passed **118 tests in 5 suites**. It includes actual session ordering,
zero-move barrier refusal, a real 24-file scan cancellation/final-save/restart-reservation test, and
an Analysis test that persists a mutation arriving during a real filesystem rename only after its
source hint is mapped.

## Remaining integration

- Face and analysis documents are post-success persistence because they cannot participate in the
  filesystem move transaction. A persistence failure may leave path hints partly updated, but
  identity hashes remain intact and the UI exposes recovery details.
- The live app's face/analysis writers are serialized by the new quiescence boundary. Arbitrary
  external code that bypasses the app services and writes `.face_data` directly is outside that
  contract.
- Continue routing any future path-keyed artifact through the registry/reassociation boundary.
- Add optional original-filename XMP metadata at an explicitly tested transaction point.
