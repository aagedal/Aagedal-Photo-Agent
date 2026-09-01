# Plan-status Develop batch-persistence continuation — 2026-09-01

## Scope and checklist result

This continuation advances Phase 4.1 of the v3 app-improvement audit by closing the unowned task-lifetime and
result-publication gap in multi-image Develop settings paste. It does not complete a broad Phase 4.1 checklist
substep, so the audit remains at 63 of 75 completed substeps.

## Batch-persistence ownership

`DevelopPersistenceSessionCoordinator` now owns each multi-image paste task together with its request and
workspace identities, the pending-operation count, explicit cancellation entry point, and observable success,
cancellation, or failure outcome. The existing serialized metadata write engine remains injected by
`EditWorkspaceView`; XMP field serialization, angled-crop aspect grouping, and structured crop, mask, HSL,
curve, and watermark data are unchanged.

The lifecycle policy distinguishes durable work from UI publication:

- overlapping requests may all finish, because each can already have committed part of its requested file set;
- only the latest request may publish an outcome into its active workspace;
- ending or replacing a workspace rotates its identity and clears visible state without cancelling an already
  started write; and
- an explicit request cancellation publishes a distinct cancellation outcome when the session is still current.

The multi-image paste path now delegates task ownership to the coordinator and snapshots its injected write
engine. A current-session failure is presented to the user in a Develop alert instead of being confined to an
error log.

## Characterization and validation

Three new lifecycle characterizations cover success, failure, explicit cancellation, latest-request-wins overlap,
and teardown that preserves durable completion while rejecting late UI publication. The existing source contract
also verifies coordinator routing and removal of the old log-only failure path.

- Focused `DevelopPersistenceSessionCoordinatorTests`: 10 tests passed.
- Adjacent persistence, interactive-render, version-session, and interaction-behavior regression: 44 tests in
  4 suites passed.
- `scripts/ci/validate_repository.sh`: passed generated metadata, release metadata, JSON, plist/project,
  provenance, privacy, conflict-marker, and whitespace checks.
- Fresh-derived serial unfiltered test gate: 1,835 tests in 215 suites passed in 58.445 seconds.
- Result bundle: `/tmp/aagedal-v3-batch-persistence-derived/Logs/Test/Test-Aagedal Photo Agent
  Tests-2026.09.01_12-07-23-+0200.xcresult`.

## Remaining boundary after this session

Twelve audit substeps remain open. Phase 4.1 still needs broader ownership and decomposition work, including task
completion/result publication for the Primary XMP/history path and the remaining source-decode, render-policy,
Metal-publication, and geometry-heavy view boundaries. This batch does not change filesystem semantics or satisfy
the Phase 3.1 real-volume evidence gates: lower-priority direct paths, local SSD/network/iCloud/read-only/large-
library measurements, signposts, and Thread Performance Checker evidence remain.

The established manual and external release gates also remain, including multi-window/menu/focus behavior,
assistive-technology and keyboard-only passes, real-device power checks, signed Sparkle/install validation, C2PA
trust-chain verification, packaged optional-model installation/rollback, and final release evidence.
