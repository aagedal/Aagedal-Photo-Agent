# Plan-status archive-preview, raw-metadata, and Clean Feed continuation — 2026-08-30

## Scope and checklist result

This continuation implemented three independent code-only slices from the v3.0 app-improvement audit.
Keyword-list archive preview and raw-metadata app-sidecar loading advance the broad Phase 3.1 filesystem
boundary; the Clean Feed publication coordinator advances Phase 4.1 Develop state ownership. Direct-path
inventory and real-volume measurements remain incomplete, and Develop still has broader render-policy and
persistence ownership to extract. The audit therefore stays **63 of 75 checklist substeps complete**.

## Keyword-list archive preview owner

Keyword-list backup preview now crosses `KeywordListsArchivePreviewService`, a serialized actor that owns
security-scoped archive access, `ditto` extraction, and manifest reads. Its immutable result distinguishes
cancellation before access, cancellation before the synchronous operation, and cancellation after the
non-preemptible read. The import sheet owns request identity, cancels superseded or disappearing work, and
rejects stale completion before publishing the preview.

Focused tests prove off-main execution, zero-I/O pre-cancellation, serialization with queued cancellation,
post-read cancellation evidence, and the view's request-identity/cancellation source contract. Existing
keyword-archive format and round-trip coverage remains intact.

## Raw-metadata app-sidecar load owner

`RawMetadataSidecarLoadService` now serializes app-sidecar discovery, security-scoped synchronous loading,
and JSON encoding away from MainActor. It returns an immutable text snapshot or explicit not-found and
before/after-read cancellation evidence. `RawMetadataView` uses image-scoped request identity, cancels work
on disappearance, and rejects late results from an earlier image.

Focused coverage proves the synchronous access closure executes off MainActor, pre-cancelled work performs
no read, cancellation after a non-preemptible read remains observable, and the view delegates through the
service instead of reading the app sidecar directly.

## Develop Clean Feed publication owner

`DevelopCleanFeedPublicationCoordinator` is the named MainActor owner for the workspace-lifetime Clean Feed
session. It owns Metal mirror installation and teardown, live-versus-fallback publication policy, crop
freezing while the crop tool is active, redraw requests, and continuous-rendering state. `EditWorkspaceView`
delegates Clean Feed lifecycle and publication to the coordinator while retaining its existing rendering and
image-loading boundaries.

Four characterizations cover workspace activation/teardown, live publication with crop freeze, fallback
publication, and view delegation.

## Validation

The combined implementation selection passed **17 tests in 4 suites**:

```text
/private/tmp/aagedal-v3-next-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_21-52-17-+0200.xcresult
```

The final serial unfiltered run passed **1,745 tests in 203 suites** after 62.461 seconds:

```text
/private/tmp/aagedal-v3-next-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_21-53-10-+0200.xcresult
```

The complete `scripts/ci/validate_repository.sh` gate passed generated-document, release metadata, JSON/plist/
project, bundled-component provenance, logger and investigation privacy, conflict-marker, and whitespace
checks. The host emitted the previously documented detached-signature, App Intents/KVS, LMDB map-size, and
SwiftUI background-publication diagnostics; none produced a test failure.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work remains in core image
presentation reads, keyword archive/editor commits, metadata and Develop template CRUD, and several MainActor
stores. Its exit gate still needs local SSD, network-volume, iCloud-placeholder, read-only-volume,
large-folder, signpost, and Thread Performance Checker evidence. Phase 4.1 still needs broader Develop
persistence/undo routing, interactive render policy and throttling, named-version modal state, and remaining
mask/watermark drag geometry ownership.

Manual and external gates remain protected release-branch configuration; focused Known People privacy/legal
review; real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS
validation.
