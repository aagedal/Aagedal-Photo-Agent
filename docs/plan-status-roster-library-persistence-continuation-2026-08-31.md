# Plan-status roster-library persistence continuation — 2026-08-31

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary for the reusable Teams library. The
library's directory scans, coordinated record reads and writes, tombstone cleanup, conflict resolution,
deletion transaction, and remote-change reload previously ran synchronously on MainActor. They now cross one
serialized persistence service. Other direct paths, real-volume measurements, and Thread Performance Checker
evidence remain open, so the audit remains **63 of 75 checklist substeps complete**.

## Serialized roster persistence

`RosterLibraryPersistenceService` owns Teams-root preparation, stable directory enumeration, tombstone
inspection and retention cleanup, tombstone-shadowed record removal, corrupt-record backup, iCloud conflict
selection, JSON commits, and verified durable deletion. Loads return an immutable sorted snapshot or explicit
pre-access/inspected-prefix cancellation evidence. Prefix evidence retains every cleanup URL that was already
durably changed before cancellation.

Upsert and delete results distinguish cancellation before mutation from cancellation observed after a
non-preemptible durable commit. The observable `RosterStore` publishes every committed mutation even when the
requesting task was cancelled, stamps actor-reported cleanup and write paths for self-write filtering, and
publishes complete load snapshots only when their request identity is current. Remote notifications now collapse
into one complete actor-owned snapshot instead of mixing individually coordinated record reads with old state.

## UI and workflow ownership

The Teams library and match setup explicitly await initial loading. Add, delete, debounced autosave, dismissal
flush, Known-People linking, iCloud-route reload, and remote-change handling now await the serialized boundary.
Instance-injected storage roots and deletion I/O keep roster tests isolated from the process singleton and the
user's real Teams library.

## Validation

Five focused service characterizations cover pre-access cancellation with zero I/O, off-main immutable sorted
loads, exact cancellation prefix evidence, durable post-write cancellation, and the source ownership contract.
The two existing deletion characterizations were updated to await the boundary and use instance-injected roots.

The affected seven-suite selection passed **55 tests**, covering roster persistence, player resolution, team
colour clustering, Sports tagging, roster export, and iCloud coordination. The complete
`scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata, JSON/plist/project
validation, bundled artifact provenance, unified-log and investigation privacy checks, conflict scanning, and
whitespace validation. A fresh-derived, serial, unfiltered run passed **1,827 tests in 214 suites** in 57.545
seconds. Its result bundle is
`/tmp/aagedal-v3-roster-full-derived/Logs/Test/Test-Aagedal Photo Agent Tests-2026.08.31_23-09-20-+0200.xcresult`.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 retains lower-priority direct filesystem paths and
its local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread
Performance Checker exit evidence. Phase 4.1 retains broader persistence task lifetime/cancellation/result
publication and remaining `EditWorkspaceView` decomposition.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
