# Plan-status RAW archive security-scope continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. RAW archive batches now acquire and release configured ingest
and archive-root security scopes through a serialized actor instead of invoking the synchronous file-provider APIs
from the MainActor-inheriting ContentView task. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Complete archive-batch access boundary

`RAWArchiveSecurityScopeService` receives an immutable request containing the configured roots. The request
standardizes and deduplicates them, so a folder configured in both roles receives only one access attempt. The actor
records only roots for which `startAccessingSecurityScopedResource()` returned true; an unavailable optional claim
does not prevent the archive from continuing, preserving the previous behavior, and is never stopped later.

Successful claims remain active while the established export-directory and render services perform the batch. Once
the item loop finishes, ContentView awaits an explicit actor release before publishing completion. Roots are released
in reverse acquisition order and immutable release evidence identifies the exact balanced set.

Cancellation is sampled before the first access and after every synchronous, non-preemptible acquisition. A request
cancelled while one of those APIs is running immediately releases every successful root in its inspected prefix and
returns cancellation evidence instead of starting any render. Normal item-loop cancellation still reaches the same
explicit release boundary before the cancelled batch result is published.

## Characterization and validation

Four new characterizations prove that:

- unique roots are inspected in order while only successful claims are released;
- cancellation during acquisition releases the exact successful prefix and does not inspect later roots;
- acquisition and release execute away from MainActor; and
- ContentView delegates both calls to the actor and contains no direct configured-root security-scope access.

Validation completed with:

- the focused RAW archive helper suite: 24 tests passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,008 tests in 231 suites passed in 63.721 seconds, with zero
  failures.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_22-55-25-+0200.xcresult` in Xcode DerivedData. Automated evidence is
complete for this bounded continuation, while the remaining manual and real-volume gates below are deliberately not
claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
