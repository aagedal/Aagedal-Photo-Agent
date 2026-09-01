# Plan-status Develop Primary-persistence continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by closing the remaining Develop-session
ownership gap around Primary XMP/history request completion and result publication. It does not complete the broad
Phase 4.1 extraction gate, so the audit remains at 63 of 75 completed substeps.

## Primary persistence ownership

`DevelopPersistenceSessionCoordinator` now owns each Primary save's awaiting task, request identity, image and
workspace identities, pending count, explicit cancellation, and observable success, cancellation, or failure
outcome. The operation is invoked synchronously so `MetadataViewModel` captures the exact edit that requested the
save. Its existing serialized metadata/history transaction remains injected and continues to own XMP-only saves,
the non-RAW embedded-CRS reset exception, partial-commit semantics, and durable history baselines.

The lifecycle policy is image scoped:

- overlapping saves may finish, but only the newest request may publish a result;
- changing images or ending the workspace clears visible pending/result state and rejects late completion;
- explicit cancellation stops the coordinator-owned waiter without claiming that already-entered durable work was
  rolled back; and
- a current failure is presented in a Develop alert instead of remaining only in `MetadataViewModel.saveError`.

Normal adjustment commits and Develop resets both route through the same helper. Named-version persistence remains
on its existing independently owned coordinator and JSON boundary.

## Characterization and validation

Three new characterizations cover success, writer-reported cancellation, explicit waiter cancellation, failure,
latest-request-wins overlap, and image replacement with a late completion. The source contract verifies both
Primary entry points and the active-workspace error presentation.

- Focused `DevelopPersistenceSessionCoordinatorTests`: 13 tests passed.
- Adjacent persistence, interactive-render, version-session, and interaction-behavior regression: 47 tests in
  4 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Serial unfiltered test gate: 1,838 tests in 215 suites passed in 59.136 seconds.
- Result bundle: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Logs/Test/Test-Aagedal Photo Agent Tests-2026.09.01_14-59-00-+0200.xcresult`.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs broader source-decode, render-policy, Metal-publication,
geometry, and view-decomposition ownership before the major-feature exit gate can be claimed. Phase 3.1 also
remains open for lower-priority direct filesystem paths plus local SSD, network, iCloud-placeholder, read-only,
large-library, signpost, and Thread Performance Checker evidence.

The established manual and external release gates remain: branch protection, focused Known People privacy/legal
review, real FTP/FTPS/SFTP drills, assistive-technology and keyboard-only passes, real-device power and Instruments
benchmarks, production AuraFace publishing/install/rollback, and final signed release validation.
