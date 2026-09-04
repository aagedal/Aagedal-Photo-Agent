# Plan-status FTP upload sidecar continuation — 2026-09-05

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. FTP upload preflight and merge no longer synchronously read
XMP sidecars from `FTPUploadView` on MainActor. Those reads, including the conditional native-dimension probes
needed to translate angled crops, now run through one serialized actor and return immutable evidence. The audit
remains at 66 of 75 completed substeps, with nine remaining.

## Serialized sidecar boundary

`FTPUploadSidecarLoadService` accepts an immutable request identifier and ordered file URLs. It serializes the
synchronous XMP reads away from MainActor and returns the exact inspected URL prefix plus an immutable metadata
map. Cancellation is explicit around the non-preemptible filesystem calls: a pre-cancelled request performs no
read, a cancellation observed during a batch reports only the exact inspected prefix, and cancellation observed
after the final read remains distinguishable from normal completion. Privacy-safe signposts report aggregate file
and metadata counts without paths or filenames.

`FTPUploadView` now keys inspection to the ordered active files, both render-policy options, and an explicit
revision. A cancelled predecessor must pass an entry guard before it can claim ownership or clear visible state.
The current request loads face data and sidecars concurrently and publishes render and metadata status only when
its identity and inputs still match and the sidecar result is complete. Upload remains disabled while inspection
is in progress. The explicit merge action uses the same off-main service, tracks a separate request identity,
cancels work on input replacement or dismissal, rejects stale UI completion, and rotates the revision after a
current success or failure so the visible status is recalculated from current evidence. A write that already
entered the atomic write engine retains that engine's normal completion and rollback semantics.

## Characterization and validation

Five new characterizations prove that:

- complete requests preserve ordered, immutable sidecar evidence;
- cancellation during a synchronous read reports the exact inspected prefix;
- pre-read and post-complete-read cancellation remain distinguishable;
- synchronous reads stay off MainActor and queued work remains serialized; and
- `FTPUploadView` rejects cancelled predecessors before they claim ownership, delegates reads, gates publication
  on a complete current request, tracks and cancels merge work across replacement or dismissal, exposes the
  inspection state, and contains no direct synchronous sidecar load.

Validation completed with:

- the focused FTP upload sidecar suite: 5 tests passed;
- the adjacent FTP selection: 35 tests in 7 suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,028 tests in 233 suites passed with zero failures.

The final full-run result bundle is `Test-Aagedal Photo Agent Tests-2026.09.05_00-05-33-+0200.xcresult` in Xcode
DerivedData. Automated evidence is complete for this bounded continuation, while the remaining manual and
real-volume gates below are deliberately not claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths. The next bounded
candidate is the Metadata editor's XMP, JSON-history, timestamp, and sidecar-reconciliation reads. The Known People
database cache-miss/reload path is a larger API migration, while Compare and Analysis retain repeated rename and
identity-resolution work that should be handled as one shared slice. The broad phase still requires real local
SSD, network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
