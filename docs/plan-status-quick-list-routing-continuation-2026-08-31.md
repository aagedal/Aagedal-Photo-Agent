# Plan-status Quick List mutation and iCloud routing continuation — 2026-08-31

## Scope and checklist result

This continuation implemented two related Phase 3.1 filesystem slices. Metadata-panel Quick List additions
now share the serialized flat-list persistence boundary with Settings editors, and Keyword Lists iCloud route
changes now resolve and reconcile their roots on a dedicated actor. These changes advance the broad direct-path
inventory, but its remaining paths, real-volume measurements, and Thread Performance Checker evidence stay
open, so the audit remains **63 of 75 checklist substeps complete**.

## Metadata Quick List mutation boundary

`KeywordListEditorPersistenceService` now owns the complete read/merge/write transaction used when Metadata
adds current field values to a Quick List. It reports missing destinations without a MainActor existence probe,
serializes appends with editor saves, preserves first-use text/CSV import behavior and security-scope lifetime,
normalizes and deduplicates entries, and distinguishes no-op, cancellation, and durable post-write evidence.

`MetadataPanel` cancels superseded work and gates prompts and error publication by request identity. Every
durable mutation is still published through `KeywordListsStore` before the UI ownership check, so observers do
not retain stale list snapshots when the panel disappears during a non-preemptible write. The prior best-effort
managed-list fallback remains available when a user-selected first-use file cannot be created or imported.

## Keyword Lists iCloud routing boundary

`KeywordListsRoutingService` now resolves local and ubiquity-container roots and serializes route reconciliation
away from MainActor. The coordinator exposes the pending requested state, cancels superseded requests, applies
only its latest completion, and keeps turning sync off available when the cloud container is temporarily
unreachable. The obsolete synchronous store toggle was removed.

The reconciliation policy is unchanged and now directly characterized: flat Quick and Approved lists preserve
destination order and append unique source entries, while an existing structured tree is never overwritten.
Cancellation before resolution or commit mutates nothing; cancellation observed after the coordinated merge
returns durable evidence so a newer route request can reconcile from the bytes already written.

## Validation

The final affected eight-suite selection passed **55 tests**, covering Quick List creation and editor persistence,
iCloud routing, keyword-store notification and round-trip behavior, approved-list policy, structured-keyword
semantics, and keyword archive import/export.

The complete `scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata,
JSON/plist/project validation, bundled artifact provenance, unified-log and investigation privacy checks,
conflict scanning, and whitespace validation.

The final serial unfiltered current-source gate passed **1,817 tests in 212 suites** in 57.845 seconds. Its
result bundle is `/private/tmp/aagedal-v3-quick-list-routing-derived/Logs/Test/Test-Aagedal Photo Agent
Tests-2026.08.31_15-43-43-+0200.xcresult`. Xcode exited successfully with no test failures.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 retains lower-priority synchronous Settings
import/export and roster-store paths plus local-SSD, network-volume, iCloud-placeholder, read-only-volume,
large-folder, signpost, and Thread Performance Checker evidence. Phase 4.1 retains broader metadata/sidecar
persistence routing and remaining Develop view decomposition.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
