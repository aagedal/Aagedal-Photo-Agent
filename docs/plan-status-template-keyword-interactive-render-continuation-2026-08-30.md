# Plan-status template, keyword-import, and interactive-render continuation — 2026-08-30

## Scope and checklist result

This continuation implemented three independent code-only slices from the v3.0 app-improvement audit.
Metadata and Develop template CRUD plus keyword-list archive import advance the broad Phase 3.1 filesystem
boundary. The Develop interactive-render coordinator advances Phase 4.1 state ownership. The remaining
direct-path inventory, real-volume measurements, broader persistence ownership, and manual/external exit
gates remain incomplete, so the audit stays **63 of 75 checklist substeps complete**.

## Metadata and Develop template CRUD boundary

`TemplateCRUDService` now serializes metadata- and Develop-template inventory, save, delete, and export work
away from MainActor. Immutable results distinguish cancellation before a read or commit from cancellation
observed after a durable mutation or export. A save that clears an existing shortcut assignment reports the
exact durable template-ID sequence, and mutation failures retain the derived inventory for any already-written
prefix.

Both template view models own load/mutation request identities, cancel superseded work, reject stale
publication, and install immutable refreshed inventories. Metadata-template export and both template editors
now await the actor-backed operations. The shared persisted `DevelopTemplate` value and storage service are
explicitly nonisolated so Codable work executes legally on the service actor under the target's default
MainActor isolation.

Focused coverage verifies shortcut-conflict clearing, zero-I/O pre-cancellation, durable-after-cancel save and
export evidence, delete evidence, stale inventory rejection, serialized off-main Develop storage, and the
view-model source contract.

## Keyword-list archive import commit boundary

The keyword-list import sheet no longer performs archive extraction, manifest reads, list merging, and
coordinated multi-file writes synchronously on MainActor. `KeywordListsArchiveImportService` owns one complete
import on a serialized actor and receives transport-only routes containing stable identifiers, manifest kinds,
destination URLs, and append/replace policy.

The immutable result distinguishes cancellation before access, cancellation before the first write,
cancellation after a durable prefix, failure before mutation, partial durable success, and complete success.
Every committed destination is published to `KeywordListsStore` even if the sheet disappears or a request is
superseded; only sheet feedback and dismissal are gated by request identity. Existing structured-tree replace,
flat-list append/deduplication, path-containment, security-scope, and observer-notification behavior is
preserved.

Focused coverage verifies the system append path, off-main execution, actor serialization, queued
cancellation, cancellation after a non-preemptible commit, partial-success evidence, and stale UI rejection.

## Develop interactive-render owner

`DevelopInteractiveRenderCoordinator` is the named MainActor owner for workspace/image interaction lifetime,
slider-active state, preview-only versus durable-commit intent, and the 100 ms CPU-scope publication throttle.
It owns the pending task and request identity, so replacement, image navigation, or workspace teardown rejects
late scope pixels even when injected render work ignores cooperative cancellation.

`EditWorkspaceView` delegates slider, curve, HSL, mask-geometry, watermark-geometry, and scope-throttle state to
the coordinator. Concrete Core Image/Metal rendering, scope notification publication, and XMP/named-version
persistence remain injected at the existing view boundaries. Five characterizations cover lifecycle and
commit intent, coalescing, late-pixel rejection, image replacement, and source delegation.

## Integrated validation

A clean build of the complete application and unit-test targets succeeded in:

```text
/private/tmp/aagedal-v3-template-keyword-render-20260830
```

The combined implementation selection passed **71 tests in 7 suites**:

```text
/private/tmp/aagedal-v3-template-keyword-render-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_23-37-40-+0200.xcresult
```

The serial unfiltered current-source run then passed **1,763 tests in 205 suites**:

```text
/private/tmp/aagedal-v3-template-keyword-render-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_23-38-02-+0200.xcresult
```

The host emitted the previously documented detached-signature, App Intents/KVS, LMDB map-size, and SwiftUI
background-publication diagnostics; none produced a build issue or test failure.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work remains in core image-presentation
reads, keyword archive export/editor paths, and other lower-priority MainActor stores. Its exit gate still needs
local SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread Performance
Checker evidence. Phase 4.1 still needs broader metadata/sidecar persistence and undo routing, named-version
modal state, and remaining mask/watermark geometry ownership.

Manual and external gates remain protected release-branch configuration; focused Known People privacy/legal
review; real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS
validation.
