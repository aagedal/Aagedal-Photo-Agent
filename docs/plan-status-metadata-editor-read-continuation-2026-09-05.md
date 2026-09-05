# Plan-status Metadata editor read continuation — 2026-09-05

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Passive Metadata-editor loading, Copy Previous, batch
selection, variable processing, and post-processing refresh no longer synchronously read XMP sidecars, app JSON
sidecars/history, or reconciliation timestamps from `MetadataViewModel` on MainActor. The audit remains at 66 of
75 completed substeps, with nine remaining.

## Serialized source-facts boundary

`MetadataEditorReadService` accepts an immutable request identifier, ordered image URLs, a frozen folder URL, and
the already-serialized embedded metadata needed for timestamp reconciliation. One actor serializes the synchronous
XMP and app-sidecar reads away from MainActor and returns immutable per-image facts. The XMP read retains its
existing service-owned Camera Raw and angled-crop behavior; app-sidecar facts include the complete JSON history;
and single-image reads freeze the existing image/XMP modification-time reconciliation verdict in the same
off-main operation.

Cancellation is explicit around the non-preemptible filesystem calls. A pre-cancelled request performs no read,
a cancellation observed during a selection reports only its exact inspected prefix, and cancellation observed
after the final read remains distinguishable from normal completion. Privacy-safe signposts report aggregate
image, XMP, and app-sidecar counts without paths, filenames, or editorial values.

`MetadataViewModel` publishes only complete facts from the current request, frozen folder, and exact ordered
selection. The explicit UUID prevents an A→B→A or same-image reload from accepting an older completion. Batch
loading derives its pending-sidecar flag from the same immutable snapshot instead of performing a second sync
read. Copy Previous and variable processing also reuse that boundary, while post-processing refresh consumes one
source snapshot rather than separately re-reading JSON history.

## Characterization and validation

Seven new characterizations prove that:

- complete ordered XMP, JSON-history, and reconciliation facts are produced off MainActor;
- pre-read, partial-prefix, and post-complete-read cancellation states remain explicit;
- queued requests are serialized and a cancelled queued request never touches storage;
- a production fixture freezes XMP, JSON history, and modification-time reconciliation together;
- repeated same-image loads publish only the newest request's result; and
- the passive Metadata call sites await the service, require complete request-owned evidence, and contain no
  direct synchronous sidecar or reconciliation reads.

Validation completed with:

- the focused Metadata editor read suite: 7 tests passed;
- the adjacent Metadata, sidecar, reconciliation, Copy Previous, and variable selection: 83 tests in 7 suites
  passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,035 tests in 234 suites passed with zero failures.

The final full-run result bundle is `Test-Aagedal Photo Agent Tests-2026.09.05_14-23-02-+0200.xcresult` in Xcode
DerivedData. Automated evidence is complete for this bounded continuation, while the remaining manual and
real-volume gates below are deliberately not claimed.

## Remaining boundary after this session

`MetadataViewModel` still has synchronous XMP existence/load and JSON baseline probes coupled directly to writes,
plus synchronous sidecar deletions. Those should move as complete read-modify-write transactions behind the actors
that own their commits; separating only their reads would introduce time-of-check/time-of-use races. Phase 3.1 also
retains the Known People database cache-miss/reload API migration and the shared Compare/Analysis rename-identity
slice. The broad phase still requires real local-SSD, network-volume, iCloud-placeholder, read-only-volume,
large-library, signpost, and Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR
Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
