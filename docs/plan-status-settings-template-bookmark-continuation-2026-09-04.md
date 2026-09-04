# Plan-status Settings template bookmark continuation — 2026-09-04

## Scope and checklist result

This continuation advances the broad Phase 3.1 filesystem and responsiveness boundary without claiming its
remaining inventory or real-volume measurement gates. Settings launch-time Templates-folder bookmark resolution,
stale-bookmark refresh, and chooser-time bookmark creation no longer invoke security-scoped bookmark APIs on
MainActor. The audit remains at 66 of 75 completed substeps, with nine remaining.

## Serialized bookmark boundary

`TemplatesFolderBookmarkService` now serializes bookmark resolution and creation on its actor. Immutable
request-tagged results distinguish failure, cancellation before access, cancellation after a synchronous resolution,
and a completed creation that observed cancellation after access. Security-scope acquisition and release remain
balanced around bookmark creation, including failed creation.

`SettingsViewModel` starts restoration asynchronously, publishes only a complete result for the current request,
and persists refreshed bookmark data without repeating the API on MainActor. Selecting a replacement folder
invalidates any launch restoration before awaiting creation, while Clear cancels and invalidates pending work so a
late result cannot restore a cleared path or bookmark. Metadata and Develop template reloads now start only after
the selected-folder request returns.

The template storage services continue to resolve the configured directory inside their existing actor-owned CRUD
and import boundaries. This slice removes the remaining duplicate bookmark access from Settings presentation and
does not claim the broader filesystem inventory complete.

## Characterization and validation

Four new characterizations cover stale resolution and refresh away from MainActor, balanced security-scope access,
complete Settings publication and persistence, clearing the durable selection, pre-access cancellation without any
bookmark call, and explicit post-access cancellation for both resolution and creation.

Validation completed with:

- the focused Templates-folder bookmark suite: 4 tests passed;
- the adjacent Templates-folder, metadata-template, Develop-template, and iCloud selection: 53 tests in four suites
  passed;
- `scripts/ci/validate_repository.sh`: passed; and
- the serial unfiltered `Aagedal Photo Agent Tests` run: 1,993 tests in 230 suites passed in 68.888 seconds.

The full-run result bundle is
`Test-Aagedal Photo Agent Tests-2026.09.04_21-31-43-+0200.xcresult` in Xcode DerivedData. Automated evidence is
complete for this bounded continuation; the remaining manual and real-volume gates below are deliberately not
claimed.

## Remaining boundary after this session

Phase 3.1 still needs the remaining lower-priority direct filesystem and cached-model paths, including the Import
backup-destination bookmark path, plus real local SSD, network-volume, iCloud-placeholder, read-only-volume,
large-library, signpost, and Thread Performance Checker evidence. Phase 3.2 still needs the representative RAW/HDR
Instruments benchmark.

The other open gates remain protected-release-branch enforcement, focused Known People privacy/legal review, real
FTP/FTPS/SFTP drills, assistive-technology and keyboard-only validation, and an AuraFace model-omitted release
candidate plus supported-macOS production-server install/offline/update/rollback/removal/interrupted-or-corrupt-
download drills.
