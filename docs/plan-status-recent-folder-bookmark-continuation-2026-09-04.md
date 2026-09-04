# Plan-status Open Recent bookmark continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Launch-time Open Recent bookmark resolution and per-folder
bookmark creation no longer invoke security-scoped bookmark APIs on MainActor. The audit remains at 66 of 75
completed substeps, with nine remaining.

## Serialized bookmark boundary

`RecentFolderBookmarkService` now serializes stale-bookmark resolution, access retention, and bookmark creation on
its actor. Loads return one immutable request-tagged folder snapshot; cancellation before access or after an exact
resolved prefix is explicit, and the MainActor store publishes only a complete current snapshot. Duplicate repair,
the ten-item limit, legacy path-only records, stable identities, and stale bookmark refresh persistence are
preserved.

Opening a folder now awaits the bookmark actor before the filesystem scan, retaining security scope before any
descendant work while allowing the UI actor to remain responsive. A created bookmark returns immutable access
evidence even if cancellation arrives after the synchronous API completes. `Clear Menu` invalidates both an
in-flight load and an in-flight creation result so late work cannot repopulate the cleared cache.

## Characterization and validation

Two new characterizations prove that both resolution and creation run away from MainActor and that a pre-cancelled
batch performs no bookmark resolution or partial cache publication. Existing tests continue to cover idempotent
scope claims, retry after a failed claim, stale bookmark refresh, equivalent-path deduplication, oversized and
duplicate cache repair, and legacy records.

Validation completed with:

- the focused `RecentFoldersStoreTests` suite: 8 tests passed;
- the adjacent Recent Folders and source-revision selection: 18 tests in two suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 1,986 tests in 229 suites passed in 67.329 seconds.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_20-59-19-+0200.xcresult` in Xcode DerivedData. Automated evidence is
complete for this bounded continuation; the remaining manual and real-volume gates below are deliberately not
claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem/cached-model paths, including Favorite-folder
bookmark resolution and creation, plus real local SSD, network-volume, iCloud-placeholder, read-only-volume,
large-library, signpost, and Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR
Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
