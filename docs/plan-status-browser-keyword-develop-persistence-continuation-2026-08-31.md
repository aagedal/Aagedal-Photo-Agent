# Plan-status Browser sidecar, keyword editor, and Develop persistence continuation — 2026-08-31

## Scope and checklist result

This continuation implemented three bounded code slices from the v3.0 app-improvement audit. Browser XMP
sidecar batches and flat keyword-list editor persistence advance the broad Phase 3.1 filesystem boundary.
Develop undo/session ownership advances Phase 4.1. The remaining direct-path inventory, real-volume
measurements, broader Develop persistence and modal/geometry ownership, and manual or external exit gates
remain incomplete, so the audit stays **63 of 75 checklist substeps complete**.

## Browser XMP sidecar batch boundary

Browser basic-metadata loading no longer launches an unbounded task group of synchronous XMP sidecar reads.
`BrowserXMPSidecarLoadService` serializes each batch away from MainActor and returns immutable evidence for a
complete read, cancellation before any read, cancellation after an exact processed prefix, or cancellation
after the final non-preemptible read. The Browser owner gates parsing, publication, and deferred cleanup by
request identity and folder identity, and a folder switch invalidates pending metadata work before replacement
state is installed.

Five focused characterizations cover off-main execution, zero-work pre-cancellation, exact partial-prefix
evidence, complete evidence when cancellation arrives after the final read, and the Browser source contract.

## Flat keyword-list editor persistence boundary

Flat keyword-list editor loads and instant-save writes now cross `KeywordListEditorPersistenceService`.
The actor serializes coordinated iCloud/local access, normalizes the exact saved payload, and distinguishes
pre-access, pre-read, post-read, pre-commit, and durable post-commit cancellation. The editor cancels superseded
work and rejects stale UI feedback by request identity. Every durable commit still publishes the exact normalized
entries through `KeywordListsStore`, including when the sheet disappears before completion, so approved-list
caches and other observers do not miss an on-disk mutation.

Six focused characterizations cover off-main loading, missing files, pre-cancellation, queued cancellation and
serialization, durable cancellation-after-write evidence, and the SwiftUI publication contract. The adjacent
keyword-store and approved-list selection also passed.

## Develop persistence-session owner

`DevelopPersistenceSessionCoordinator` now owns the Develop workspace and image lifecycle, the image-scoped
`UndoManager`, undo/redo restoration, stale restoration rejection after navigation, the workspace-wide set of
edited preview URLs, and explicit preview-only, Primary-commit, or named-version-commit intent. Same-image preview
reloads preserve undo history, while workspace restart and actual image replacement invalidate it. Existing XMP
sidecar and named-version JSON operations remain injected at `EditWorkspaceView`, preserving their established
durable write semantics.

Six focused coordinator characterizations cover lifecycle, dirty-URL inventory, persistence intent, undo/redo,
stale callbacks, same-image refresh, and view delegation. The adjacent Develop interaction suite also passed.

## Validation

The combined six-suite regression selection passed all **52 tests**:

- 5 Browser XMP sidecar boundary tests;
- 6 keyword-list editor boundary tests plus 11 keyword store and approved-list tests; and
- 6 Develop persistence coordinator tests plus 24 Develop interaction tests.

The complete `scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata,
JSON/plist/project validation, bundled artifact provenance, unified-log and investigation privacy checks,
conflict scanning, and whitespace validation.

The final serial unfiltered current-source gate passed **1,923 tests** in 62.736 seconds. Its result bundle is
`/private/tmp/aagedal-v3-session-derived/Logs/Test/Test-Aagedal Photo Agent
Tests-2026.08.31_00-20-50-+0200.xcresult`. Xcode exited successfully with no test failures.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work remains in lower-priority direct
paths, including generic approved-list import parsing, Settings quick-list synchronization/import/export,
keyword-list iCloud migration and routing, and broader roster-store operations. Its exit gate still needs local
SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread Performance Checker
evidence.

Phase 4.1 still needs broader metadata/sidecar persistence routing, named-version modal ownership, and remaining
mask/watermark geometry ownership. Manual and external gates remain protected release-branch configuration;
Known People privacy/legal review; real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion,
text-size, and display validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing
with supported-macOS validation.
