# Batch rename execution validation

**Validated:** 2026-08-21  
**Scope:** Phase 3 two-phase filesystem transaction, cancellation, and rollback reporting

## Implemented contract

- The executor accepts only an immutable `RenamePlan`; it never rerenders recipes, discovers extra
  artifacts, or silently changes requested destinations.
- Live preflight verifies plan executability, matching image action, existing unique sources,
  reserved unique unoccupied destinations, same-directory actions, writable directories, and a
  bounded unique temporary path for every move before mutation.
- Every image and its discovered sidecars/custom filename artifacts form a transaction bundle.
  All sources stage to same-directory temporary paths before any destination commits, which safely
  handles two-way swaps and longer cycles.
- Cancellation is checked before staging, metadata update, and commit boundaries. A cancelled or
  failed operation performs best-effort rollback and returns structured issues, rollback status,
  completed bundle state, the full move journal, and actual-path residuals.
- Current and legacy `.photo_metadata` JSON sidecars update their `sourceFile` to the destination
  image name after staging. Rollback restores their original bytes before restoring source paths.
- The Foundation adapter never overwrites an existing destination; injected adapters make every
  move/failure boundary deterministic in tests.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-rename-execution-build-01' \
  -jobs 2 \
  -only-testing:'Aagedal Photo Agent Tests/RenameExecutionServiceTests'
```

Result: **14 tests passed**, and the production target compiled in the same run.

## Remaining integration

- Replace browser rename alerts with the resizable planner/preview sheet and execute only accepted
  plans through this service.
- Add face/analysis/project/cache artifacts to the registry and reassociate in-memory state after
  success.
- Store the original filename in XMP at the explicitly tested transaction point.
- Keep cross-directory moves unsupported until a separate cross-volume transaction design defines
  copy durability, free-space preflight, and recovery semantics.
