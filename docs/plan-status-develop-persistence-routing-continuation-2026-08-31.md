# Plan-status Develop persistence-routing continuation — 2026-08-31

## Scope and checklist result

This continuation advances the Phase 4.1 Develop state-owner gate. The existing persistence-session owner now
routes each durable edit request to Primary XMP/history persistence or named-version persistence instead of
leaving that policy duplicated in `EditWorkspaceView`. Concrete storage operations remain injected and retain
their prior behavior. Broader persistence task lifetime, cancellation, publication, and view decomposition stay
open, so the audit remains **63 of 75 checklist substeps complete**.

## Persistence dispatch ownership

`DevelopPersistenceSessionCoordinator.performPersistence` derives intent from the active workspace, dirty
Primary state, and active named-version state. A Primary or named-version request publishes the in-memory image
snapshot exactly once and then invokes exactly one matching durable action. Inactive and unchanged workspaces
publish nothing and invoke no writer.

Both normal adjustment commits and Develop reset now cross this owner. Their established storage distinction is
unchanged: ordinary Primary adjustments remain XMP-sidecar-only, while a non-RAW reset may still clear legacy
embedded Camera Raw state and mirror the XMP sidecar. Named-version changes continue through the existing
debounced version session. The coordinator depends only on injected main-actor actions, so it remains independently
testable without coupling to `MetadataViewModel`, `XMPSidecarService`, or the version repository.

## Validation

The focused coordinator build passed **7 tests** in one suite. The affected regression then passed **34 tests**
across `DevelopPersistenceSessionCoordinatorTests`, `DevelopInteractiveRenderCoordinatorTests`,
`DevelopVersionSessionCoordinatorTests`, and `DevelopVersionCatalogTests`.

The complete `scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata,
JSON/plist/project validation, bundled artifact provenance, unified-log and investigation privacy checks,
conflict scanning, and whitespace validation.

The final serial unfiltered current-source gate passed **1,818 tests in 212 suites** in 59.914 seconds. Its
result bundle is `/private/tmp/aagedal-v3-quick-list-routing-derived/Logs/Test/Test-Aagedal Photo Agent
Tests-2026.08.31_16-56-18-+0200.xcresult`.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 retains lower-priority synchronous Settings and
roster-store filesystem paths plus local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder,
signpost, and Thread Performance Checker evidence. Phase 4.1 retains ownership of broader persistence task
lifetime, cancellation, result publication, and remaining `EditWorkspaceView` decomposition.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
