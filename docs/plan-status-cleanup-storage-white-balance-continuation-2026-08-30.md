# Plan-status cleanup, storage, and white-balance continuation — 2026-08-30

## Scope and checklist result

This continuation implements three more Phase 3.1 filesystem slices and one Phase 4.1 Develop state-owner
extraction. The work advances broad inventory and ownership gates without completing the remaining direct-path
audit, real-volume/Thread Performance Checker evidence, or the wider Develop extraction, so the app-improvement
audit remains **63 of 75 complete**.

## RAW archive signing-failure cleanup

A failed configured C2PA signing attempt no longer removes the newly rendered archive and archive sidecar with
direct `FileManager` calls in `ContentView`. `RAWArchiveSigningFailureCleanupService` serializes compensating
cleanup away from the main actor and receives an immutable request whose archive, archive-sidecar, and protected
source-sidecar identities are frozen before cleanup begins.

The operation deliberately completes both removal attempts after submission, even when cancellation is already
requested, because leaving an unsigned archive behind is less safe than pre-empting compensation. Immutable
evidence records removed, already-absent, preserved-source-sidecar, and per-item failure outcomes plus cancellation
observed before/after cleanup. A failure removing one artifact does not suppress the second attempt. Six focused
tests cover real filesystem cleanup, shared-sidecar preservation, partial failure, cancellation, off-main actor
serialization, and the `ContentView` source contract.

## Known People storage summary

Settings no longer recursively enumerates Known People storage while refreshing a MainActor data-management
summary. `KnownPeopleDataSummaryService` performs the recursive regular-file byte count on a serialized actor,
does not follow package descendants or symbolic links, checks cancellation during enumeration, and returns only
complete or cancelled immutable evidence. A cancelled scan never publishes a partial byte count.

Settings updates the people/sample counts and storage destination immediately, owns the measurement task and
request identity, cancels replacement or disappearance, and installs only the latest complete summary. Focused
coverage verifies nested byte counts, destination copy, off-main execution, serialization, queued cancellation,
and stale-publication source contracts.

## Edited-folder backup destination preparation

The Back Up Edited Files workflow no longer creates destination directories through direct `FileManager` calls
inside its detached task. It sorts the unique directory set and awaits the shared serialized
`ExportDirectoryService` for each durable creation. Cancellation before a creation mutates nothing; cancellation
reported immediately after a non-preemptible directory commit leaves the harmless directory but prevents copy
work from starting. The existing export-directory suite now includes a source contract for this path.

## Develop white-balance state owner

`DevelopWhiteBalanceSessionCoordinator` now owns image-scoped as-shot neutral data, eyedropper activation and
marquee state, sample-request identity, RAW/non-RAW display projections, representable ranges, logarithmic Kelvin
mapping, pane-to-source geometry, and explicit preview-only versus durable-commit mutation intent.

Image navigation and workspace teardown clear image-scoped state. Late RAW neutral publications are rejected by
image identity, and replaced, deactivated, or previous-image eyedropper solves cannot commit after their session
ends. Pixel averaging, the worker-safe Metal solver, metadata persistence, and render publication remain at their
existing boundaries. Seven characterizations cover lifecycle/stale publication, picker request replacement,
geometry projection, RAW and non-RAW clamping, persistence intent, log bounds, and the workspace source contract.

## Validation

A clean app and test-target build completed while running the combined touched selection. After correcting two
test-only integration issues found by that build, the selection passed **39 tests in 4 suites**:

- `ExportDirectoryServiceTests`;
- `RAWArchiveTests`;
- `ICloudSyncCoordinatorTests`; and
- `DevelopWhiteBalanceSessionCoordinatorTests`.

```text
/private/tmp/aagedal-v3-continue-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_15-51-52-+0200.xcresult
```

Final review added picker solve request identity so a replaced or ended eyedropper interaction cannot publish
late. The complete app/test targets rebuilt and all **7 tests** in the strengthened white-balance suite passed:

```text
/private/tmp/aagedal-v3-continue-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_15-54-28-+0200.xcresult
```

The final serial unfiltered current-source gate then passed **1,707 tests in 197 suites** in 57.776 seconds:

```text
/private/tmp/aagedal-v3-continue-20260830/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.30_15-56-13-+0200.xcresult
```

`scripts/ci/validate_repository.sh` passed generated-document, release metadata, JSON/plist/project, bundled
component provenance, logger and investigation privacy, conflict-marker, and whitespace checks. The host emitted
the previously documented App Intents/KVS, LMDB map-size, detached-signature, and SwiftUI background-publication
diagnostics; none produced a build issue or test failure.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 needs the remaining lower-priority direct-path
inventory and real local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, and Thread
Performance Checker evidence. Phase 4.1 still needs dedicated ownership for layer, broader render policy,
export, and persistence state.

Manual and external gates remain protected release-branch configuration; focused Known People privacy/legal
review; real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing plus supported-macOS
validation.
