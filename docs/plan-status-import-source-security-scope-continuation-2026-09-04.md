# Plan-status Import source security-scope continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Import source discovery now owns security-scope acquisition,
enumeration, and release on one serialized actor instead of asking a MainActor owner to open the optional secondary
source first. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Complete source-discovery access boundary

`ImportSourceDiscoveryService.discoverFiles` now starts security-scoped access after its pre-cancellation check and
balances every successful start with an actor-owned deferred stop. Both the primary source scan and optional
voice-memo source scan therefore use one boundary for the complete scope lifetime and recursive enumeration. The
voice-memo task no longer invokes the synchronous security-scope APIs before crossing to the discovery actor.

The service checks cancellation again after acquisition because the Foundation call is synchronous and cannot be
pre-empted. Cancellation requested during that call stops before directory enumeration while still releasing an
acquired scope. A false start result remains a valid attempt: discovery can continue under an already-held or
otherwise available grant, and no unmatched stop is issued.

## Characterization and validation

Four new characterizations prove that:

- security-scope start and stop execute away from MainActor and receive the exact selected root;
- successful access is balanced while an unavailable scope is not stopped;
- pre-cancellation performs no access, while cancellation during acquisition releases the acquired scope before
  surfacing `CancellationError`; and
- the voice-memo scan delegates discovery without directly invoking either security-scope API.

Validation completed with:

- the focused Import source-discovery suite: 8 tests passed;
- the complete adjacent Import selection: 45 tests across 5 suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 2,004 tests in 231 suites passed in 66.935 seconds, with zero
  failures.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_22-45-03-+0200.xcresult` in Xcode DerivedData. Automated evidence is
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
