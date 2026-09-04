# Plan-status import execution security-scope continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Import execution now owns primary-source, optional
voice-memo-source, destination, and optional backup security scopes through a serialized actor. The audit remains at
66 of 75 completed substeps, with nine remaining.

## Complete import lease boundary

`ImportExecutionSecurityScopeService` receives immutable requests captured before the import leaves its UI owner.
Each request standardizes and deduplicates roots, records only the optional access claims that actually started, and
returns exact immutable acquisition or cancellation evidence. The initial source and destination claims remain
active through planning, preflight, copying, verification, relationship persistence, and optional metadata writes.
The backup claim begins only after overwrite preflight is accepted, preserving the prior no-access-before-confirmation
behavior.

The actor-owned `withAccess` lifetime releases successful claims in reverse acquisition order after normal
completion, an early stale-result or overwrite-confirmation return, cancellation, or failure. A cancellation observed
after a synchronous, non-preemptible access call releases the complete successful prefix before any import operation
runs. An unavailable optional claim preserves the existing permissive behavior and is never stopped later.

The import plan crossing the new Sendable operation boundary is frozen into immutable destination, bundle, job, and
previous-import snapshots. UI state remains request-identity gated exactly as before.

## Characterization and validation

Five new characterizations prove that:

- duplicate roots are inspected once while unavailable claims are not released;
- acquisition and release execute away from MainActor;
- cancellation during acquisition releases the exact successful prefix and inspects no later root;
- successful and throwing operations release claims in reverse order; and
- `ImportViewModel.startImport()` delegates both initial and backup scope lifetimes to the actor.

Validation completed with:

- the focused import execution/source/view-model selection: 34 tests passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,013 tests in 232 suites passed in 66.064 seconds with zero
  failures.

The full-run result bundle is `Test-Aagedal Photo Agent Tests-2026.09.04_23-12-13-+0200.xcresult` in Xcode
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
