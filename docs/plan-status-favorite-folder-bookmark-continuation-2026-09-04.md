# Plan-status Favorite-folder bookmark continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Launch-time Favorite-folder bookmark resolution, Add to
Favorites bookmark creation, and bookmark refresh after moving a favorite root no longer invoke security-scoped
bookmark APIs on MainActor. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized bookmark boundary

`FavoriteFolderBookmarkService` now serializes stale-bookmark resolution, access retention, and bookmark creation
on its actor. Loads return one immutable request-tagged snapshot; cancellation before access or after an exact
inspected prefix is explicit, and `BrowserViewModel` publishes only a complete current snapshot. Stable favorite
identities, display-name repair after bookmark resolution, legacy path-only records, and refreshed-bookmark
persistence are preserved.

Add to Favorites first awaits the one-time load so a late launch snapshot cannot overwrite a new favorite. The
actor returns immutable bookmark evidence, including whether cancellation arrived after the synchronous API, and
the MainActor commits only the matching result. Moving a favorite root also creates its replacement bookmark on the
actor before publishing the move side effects; if no replacement can be created, the existing move-following
bookmark is retained instead of being discarded.

The root view now loads favorites in a cancellation-aware SwiftUI task and starts top-level favorite scans only
after bookmark resolution and security-scope retention complete. This preserves the access-before-descendant-work
ordering without blocking the UI executor.

## Characterization and validation

Three new characterizations cover stale-bookmark repair and new bookmark persistence through the browser model,
prove that resolution, access retention, refresh, and creation all execute away from MainActor, verify that a
pre-cancelled load performs no bookmark access or partial publication, and distinguish cancellation observed after
a non-preemptible bookmark creation call. Existing Recent Folder and sidebar behavior remains covered.

Validation completed with:

- the focused Recent Folders and sidebar selection: 13 tests in two suites passed;
- the adjacent bookmark, sidebar, rejected-move, and source-revision selection: 28 tests in four suites passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 1,989 tests in 229 suites passed in 65.086 seconds.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_21-21-47-+0200.xcresult` in Xcode DerivedData. Automated evidence is
complete for this bounded continuation; the remaining manual and real-volume gates below are deliberately not
claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths plus real local SSD,
network-volume, iCloud-placeholder, read-only-volume, large-library, signpost, and Thread Performance Checker
evidence. Phase 3.2 still needs the representative RAW/HDR Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
