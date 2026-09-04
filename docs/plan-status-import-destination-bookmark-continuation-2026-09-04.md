# Plan-status Import destination bookmark continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Launch-time primary and backup import-destination bookmark
resolution, stale refresh, and chooser-time creation no longer invoke security-scoped bookmark APIs on MainActor.
The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized bookmark boundary

`ImportDestinationBookmarkService` now serializes both destination bookmark lifecycles on one actor. Immutable,
request-tagged results distinguish resolution failure, cancellation before access, cancellation after synchronous
resolution or refresh, and completed creation that observed cancellation after access. Temporary security-scope
access remains balanced around bookmark creation, including creation failure.

`ImportViewModel` schedules both launch restorations asynchronously and publishes only a complete result for the
still-current primary or backup request. A stale bookmark is refreshed without repeating the API on MainActor;
failed current resolution clears its unusable persisted bookmark. Selecting another destination cancels and
invalidates its restoration before publishing the selected URL, and clearing the optional backup cancels and
invalidates pending work so a late result cannot restore the cleared URL or bookmark. Backup verification preference
restoration and immediate destination-folder suggestion refresh remain intact.

## Characterization and validation

Four new characterizations cover stale primary and backup restoration and refresh away from MainActor, balanced
security-scope access, complete selection publication and persistence, clearing persisted state, rejection of an
in-flight completion after Clear, cancellation before any bookmark call, and explicit cancellation observed after a
non-preemptible bookmark API.

Validation completed with:

- the focused `ImportViewModelTests` suite: 21 tests passed;
- the adjacent Import preflight, discovery, view-model, safe-path, and copy selection: 41 tests in five suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 1,997 tests in 230 suites passed in 69.177 seconds, with
  2,124 expanded executions and zero failures or skips.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_21-50-36-+0200.xcresult` in Xcode DerivedData. An initial concurrent
unfiltered run hit established cross-suite timeout and LMDB map-size interference; the repository's serial gate then
passed cleanly. Automated evidence is complete for this bounded continuation, while the remaining manual and
real-volume gates below are deliberately not claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
