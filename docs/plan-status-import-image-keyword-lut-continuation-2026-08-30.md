# Plan-status import, image, keyword-export, and LUT continuation — 2026-08-30

## Scope and checklist result

This continuation implemented four bounded code slices from the v3.0 app-improvement audit. Import
destination preparation, full-screen presentation reads, and keyword-list archive export advance the broad
Phase 3.1 filesystem boundary. The Develop Color LUT import coordinator advances Phase 4.1 state ownership.
The remaining direct-path inventory, real-volume measurements, broader persistence ownership, and manual or
external exit gates remain incomplete, so the audit stays **63 of 75 checklist substeps complete**.

## Import destination-directory commit boundary

Import no longer creates its planned destination folders directly inside the detached workflow task. A
deterministically ordered batch now crosses `ExportDirectoryService`, the same serialized actor used by export
and backup preparation. Its immutable result distinguishes complete creation, cancellation after an exact
durable prefix, and failure after an exact durable prefix. The browser receives `importStarted` only after
complete evidence includes every requested directory and the reveal target; cancellation or failure starts no
copy work and never implies that an already-created directory was rolled back.

Focused characterizations cover source delegation, complete ordered commits, cancellation after one durable
commit, and failure after one durable commit while preserving the untouched suffix.

## Full-screen presentation-read boundary

Cold full-screen loading and zoomed full-resolution loading no longer read XMP sidecars or ImageIO header facts
from the main-actor presentation owner. `FullScreenImagePresentationFactsService` serializes both synchronous
reads and returns one immutable snapshot containing Camera Raw settings, sidecar/file orientation, and pixel
dimensions. Results distinguish cancellation before the read from cancellation after a non-preemptible read.
The view gates publication by request identity, render generation, current URL, and task cancellation.

The focused service and source-contract suite passed all **4 tests**.

## Keyword-list archive export boundary

Keyword-list archive staging copies, manifest encoding, `ditto`, and final installation now cross
`KeywordListsArchiveExportService`. MainActor captures only stable source routes and manifest facts; the actor
returns immutable cancellation or durable-commit evidence. The archive is built as a sibling temporary file and
then replaced or moved into place, so staging failure and pre-commit cancellation leave an existing destination
untouched. Cancellation observed after installation remains attached to successful durable evidence.

The export sheet disables duplicate submission, cancels on disappearance, and rejects stale feedback by request
identity. Five focused characterizations cover off-main execution, zero-work pre-cancellation, cancellation
after commit, failure preserving prior destination bytes, and UI delegation.

## Develop Color LUT import owner

`DevelopColorLUTImportCoordinator` now owns the image-scoped file-importer presentation, target layer, security-
scoped URL lifetime, async task, request identity, cancellation, and error publication. A successful parse emits
one typed `DevelopColorLUTPersistenceIntent`; `EditWorkspaceView` deliberately retains the existing Camera Raw
mutation, undo registration, and XMP or named-version commit boundary.

Characterizations cover successful intent publication with balanced security-scope access, stale completion
after image replacement, cancellation evidence, and source delegation.

## Validation

The final shared tree passes `git diff --check`. The four implementation suites passed all **26 focused tests**:
10 import/export-directory tests, 4 full-screen presentation tests, 5 keyword-list archive export tests, and 7
Color LUT import tests. The repository validation script also passed every metadata, project, privacy,
provenance, conflict, and whitespace check.

The final serial unfiltered current-source gate passed **1,779 tests in 207 suites** in 57.953 seconds. Its
result bundle is `/tmp/aagedal-v3-image-presentation-derived/Logs/Test/Test-Aagedal Photo Agent
Tests-2026.08.31_00-00-22-+0200.xcresult`. Repeated LMDB map-capacity and expected malformed/missing-image
diagnostics remained non-failing test output; Xcode ended with `TEST EXECUTE SUCCEEDED`.

## Remaining boundary after this session

The audit still has **12 open checklist substeps**. Automatable Phase 3.1 work remains in lower-priority direct
filesystem paths and completion of the inventory; its exit gate still needs local SSD, network-volume,
iCloud-placeholder, read-only-volume, large-folder, signpost, and Thread Performance Checker evidence. Phase 4.1
still needs direct Develop undo/session dirty-URL ownership, broader metadata/sidecar persistence routing,
named-version modal state, and remaining mask/watermark geometry ownership.

Manual and external gates remain protected release-branch configuration; focused Known People privacy/legal
review; real FTP/FTPS/SFTP drills; accessibility, localization, IME, contrast, motion, text-size, and display
validation; Instruments RAW/HDR memory benchmarks; and production AuraFace publishing with supported-macOS
validation.
