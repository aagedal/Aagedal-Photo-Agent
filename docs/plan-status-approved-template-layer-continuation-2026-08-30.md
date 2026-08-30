# Plan-status approved-list, template-commit, and Develop-layer continuation — 2026-08-30

## Scope and checklist result

This continuation implemented three independent code-only slices from the v3.0 app-improvement audit.
Approved-list import and metadata-template import commit advance the broad Phase 3.1 filesystem boundary;
the Develop layer-session coordinator advances Phase 4.1 state ownership. The remaining direct-path
inventory, real-volume measurements, broader Develop render/persistence ownership, and manual/external exit
gates remain open, so the audit stays **63 of 75 checklist substeps complete**.

## Approved-list import filesystem owner

Approved keyword-list imports now cross `ApprovedListImportService`, a serialized actor that owns the
security-scoped source lifetime, size/read/decode work, and coordinated atomic destination write. Immutable
results distinguish cancellation before access, before/after the non-preemptible read, before commit, and
after a durable commit. Size limits, CSV first-column parsing, text decoding, managed storage, and user-facing
errors are preserved.

`ApprovedListService` owns a request generation per field and rejects stale completion. Settings owns and
cancels the UI task on replacement, clear, and disappearance. Committed entries travel in a source-scoped
store notification, so the importing service and backup observer receive immutable evidence without making
the approved-list observer synchronously re-read the destination on MainActor. Injected per-service defaults
and notification source identity also keep independent service owners and parallel tests from publishing one
another's transient state.

Focused coverage proves off-main execution, zero-I/O pre-cancellation, durable-after-cancel evidence, actor
serialization with queued cancellation, stale-result suppression, notification payload ownership, and the
existing matching/bypass/validation behavior.

## Metadata-template import commit owner

Accepting a metadata-template bundle no longer performs synchronous multi-file saves and inventory reads from
`TemplateViewModel`. `TemplateImportCommitService` serializes the current inventory, each coordinated durable
save, and final refresh. Cancellation before the first save mutates nothing; cancellation or failure after a
save returns the exact committed template-ID prefix, added/overwritten counts, and a derived immutable inventory.

The view model owns the commit task and request identity, actively cancels a superseded commit, rejects stale
publication, and preserves partial durable success in its visible inventory. A current partial failure names
how many templates were already imported instead of presenting an all-or-nothing error.

## Develop layer-session state owner

`DevelopLayerSessionCoordinator` is now the named MainActor owner for image-scoped layer selection, drag/drop
and hover state, rename presentation/draft, and the workspace-sticky mask-outline preference. Image navigation
and workspace teardown reset the image-scoped state through explicit lifecycle methods.

Rename, reorder, and selected-layer deletion mutate an injected `CameraRawSettings` value and return an
explicit unchanged-or-commit persistence intent. `EditWorkspaceView` retains rendering and the existing XMP/
named-version commit boundary while no longer owning the individual layer-strip state fields. Five
characterizations cover navigation/teardown, rename, sanitized ordering, successor selection, and view
delegation.

## Integrated validation and full-load stabilization

A clean build of the complete app and unit-test targets succeeded in:

```text
/private/tmp/aagedal-v3-approved-template-layer-20260830
```

The combined implementation selection passed **52 tests in 7 suites**. The FTP filesystem suite was then
included while reconciling its older short blocked-probe deadline, producing a passing **61-test selection in
8 suites**. The Delivery Receipt stale-export test replaced hot actor polling with a continuation-based event;
the affected Delivery Receipt and Develop export suites also passed focused.

Parallel unfiltered attempts exposed scheduler starvation in short diagnostic polling ceilings and one Xcode
test-worker materialization stall. No production assertion failed, and every reported suite passed immediately
when selected. The final unfiltered run disabled Xcode parallel test workers and passed **1,859 expanded test
cases**:

```text
/private/tmp/aagedal-v3-approved-template-layer-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_20-54-27-+0200.xcresult
```

The complete `scripts/ci/validate_repository.sh` gate passed generated-document, release metadata, JSON/plist/
project, bundled-component provenance, logger and investigation privacy, conflict-marker, and whitespace
checks. The host emitted the previously documented App Intents/KVS, LMDB map-size, detached-signature, and
SwiftUI background-publication diagnostics; none produced a build issue or failure in the final serial run.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work remains in synchronous template
load/save/delete/export and other lower-priority direct filesystem paths; its exit gate still needs local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread Performance Checker
evidence. Phase 4.1 still needs broader Develop render-policy/publication and persistence ownership.

Manual and external gates remain protected release-branch configuration; focused Known People privacy/legal
review; real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS
validation.
