# Plan-status Settings keyword-archive inventory continuation — 2026-08-31

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem boundary for Settings keyword archive workflows.
Archive extraction and commits were already actor-backed, but both sheets still performed coordinated
existence probes and complete list reads synchronously on MainActor to calculate displayed counts, default
import modes, and export requests. Those reads now cross a dedicated serialized service. The remaining direct
paths and real-volume/Thread Performance Checker evidence stay open, so the audit remains **63 of 75 checklist
substeps complete**.

## Immutable managed-list inventory

`KeywordListsArchiveInventoryService` receives stable source routes and count formats, performs every
coordinated existence probe and content read away from MainActor, and returns an ordered immutable snapshot.
Flat lists retain the existing normalized/deduplicated count semantics. Structured lists retain the parser's
keyword-versus-container, synonym, and related-keyword syntax without constructing UI-owned tree state on the
filesystem actor.

Cancellation before access performs no probes. Cancellation between files or after one non-preemptible read
returns the exact fully inspected prefix. Settings publishes only complete snapshots, while the explicit prefix
evidence keeps cancellation and blocked-volume behavior testable.

## Settings ownership

The export sheet owns inventory task/request identity, presents progress and retryable failure state, selects
all successfully inventoried in-scope lists by default, and builds its export request directly from the
completed snapshot. It therefore does not repeat list reads when the save panel is accepted.

The import sheet now treats archive inspection plus local-list inventory as one request lifetime. It calculates
Append-versus-Replace defaults only after both immutable snapshots are current, cancels the complete chain on
dismissal or replacement, and rejects late publication. Existing durable import notification behavior is
unchanged.

## Validation

The focused archive boundary passed **21 tests in 4 suites**. The adjacent archive, store, approved-list, and
structured-keyword regression selection passed **65 tests in 11 suites**.

The complete `scripts/ci/validate_repository.sh` gate passed generated documentation, release metadata,
JSON/plist/project validation, bundled artifact provenance, unified-log and investigation privacy checks,
conflict scanning, and whitespace validation.

An initial parallel unfiltered run exercised 1,822 tests and hit one unrelated short-deadline timeout in the
analysis export directory cancellation characterization. The final serial unfiltered current-source gate passed
**1,822 tests in 213 suites** in 62.634 seconds. Its result bundle is
`/private/tmp/aagedal-v3-settings-inventory-derived/Logs/Test/Test-Aagedal Photo Agent
Tests-2026.08.31_17-55-12-+0200.xcresult`.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Phase 3.1 retains lower-priority synchronous roster-store and
other direct filesystem paths plus local-SSD, network-volume, iCloud-placeholder, read-only-volume, large-folder,
signpost, and Thread Performance Checker evidence. Phase 4.1 retains broader persistence task lifetime,
cancellation/result publication, and remaining `EditWorkspaceView` decomposition.

Manual and external gates remain protected release-branch configuration; Known People privacy/legal review;
real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display validation;
Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS validation.
