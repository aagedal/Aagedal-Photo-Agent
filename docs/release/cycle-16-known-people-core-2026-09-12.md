# Cycle 16 — Known People core interchange

**State:** IMPLEMENTING. Core archive, local capture and managed replacement are verified;
first-time identity assignment, user-facing import/export and explicit cloud reconciliation remain.

## Candidate identity and environment

- Source base: `78f02099cc2eb0dbf6e300fc9c1f0ac65b63c1c8` on `main`, with the
  cycle-16 files uncommitted during validation.
- Host: Apple Silicon (`arm64`), macOS 27.0 build 26A428.
- Scheme/destination: `Aagedal Photo Agent Tests`, Debug, `platform=macOS`,
  parallel testing disabled for the coordinator runs.
- No app candidate was assigned and no native UI result is claimed for this core-only slice.

## Implemented boundary

- `KnownPeoplePackageArchive` reads and writes deterministic STORED ZIP32
  `.aagedalpeople.zip` archives. It validates headers, exact local/central agreement,
  paths, sizes, CRC, inventory hashes, JPEG and FEM2 before extraction. Publication and
  cleanup keep descriptor-relative ownership and truthful recovery evidence.
- `.aagedalpeople` is declared as exported UTI `no.aagedal.people-library`, conforming
  to `com.apple.package`. Bare `.aagedalpeople` items are directory packages; ZIP bytes
  use the compound `.aagedalpeople.zip` extension.
- `KnownPeopleManagedStoreReplacement` plans same-library, different-library and
  untracked replacement; refuses iCloud/routing overlap; rechecks route, parent, root and
  inventory through held descriptors; stages and fsyncs the complete projection; then
  performs one atomic root swap. Post-commit failures retain the displaced root and report
  the installed state rather than describing a committed change as rolled back.
- Managed state binds the exact admitted package and its service-local projection. Raw
  package paths remain lowercase; service-local person and thumbnail filenames use exact
  uppercase `UUID.uuidString` so case-sensitive volumes match ordinary CRUD behavior.
- Whole-root replacement reserves every local path spelling, including `/tmp` aliases and
  lexically nested symlink escapes. It invalidates peer caches and generation-discards
  deferred thumbnail and import work before notifying observers.
- Valid admitted AuraFace state protects the installed v3 store from a stale global
  embedding-version migration. Enabling Known People iCloud sync fails closed while local
  state requires explicit reconciliation or its state record is malformed.
- `KnownPeopleLocalStoreSnapshotBuilder` captures one descriptor-bound, read-only local
  view without invoking database migration. It rejects links, hardlinks, unsafe entries,
  changed roots, malformed JPEG/FEM2 and case-variant local UUID paths. Exact admitted
  bytes are reused only when both package and projection hashes remain bound.

## Corrections found during review

Focused integration and independent review found and corrected route equality that depended
on a URL directory hint, `/tmp` alias reservation bypass, lexical child-symlink reservation,
case-sensitive local UUID filename mismatch, unchecked `readdir` errors, archive staging
cleanup after post-write admission failure, cross-suite preference-state interference and a
whole-root accounting cap smaller than the valid admitted-package-plus-projection union.

The combined root allows 410,010 entries and 1.5 GB; raw-package and projection scans retain
their 200,100-entry / 600 MB defensive limits. Directory packages retain the schema cap of
200,001 files and 500 MB. Strict ZIP32 transport is limited to 65,534 entries because `0xffff`
is the ZIP64 sentinel. Larger valid libraries must use the directory package; both apps and
their UI must use this same rule.

## Verification

- Coordinator focused integration: 149 declared tests / 346 expanded cases across
  `KnownPeoplePackageArchiveTests`, `KnownPeopleManagedStoreReplacementTests`,
  `KnownPeopleLocalStoreSnapshotBuilderTests`, `ICloudSyncCoordinatorTests` and
  `KnownPeopleServiceTests`; pass in 22.087 seconds.
  Log: `/private/tmp/aagedal-known-people-combined-v3.log`.
  Result: `/private/tmp/aagedal-known-people-combined-v3.xcresult`.
- Complete suite after the final source correction: 2,781 tests / 304 suites; pass in
  113.368 seconds. Log: `/private/tmp/aagedal-full-known-people-checkpoint-v2.log`.
  Result: `/private/tmp/aagedal-full-known-people-checkpoint-v2.xcresult`.
- Repository validation after documentation updates: pass.
  Log: `/private/tmp/aagedal-known-people-repository-v2.log`.
- `plutil -lint` passes for `Info.plist` and the project file; `git diff --check` passes.
- Independent review approves source, tests, UTI and project wiring after all findings.

## Remaining work

1. Atomically assign stable library and installation identity to an untracked populated or
   empty local root, using the same whole-root transaction and retaining exact recovery evidence.
2. Add high-level service preparation/commit/export APIs, then integrate one reusable
   MainActor transfer controller into Settings and Expanded Known People.
3. Keep schema-2 replacement visibly separate from additive legacy ZIP import. Present
   same/different/untracked decisions, counts, IDs, missing-editor notice, cancellation and
   recovery outcomes. Hold security-scoped access through each asynchronous operation.
4. Implement explicit local-to-cloud reconciliation before allowing iCloud enablement.
5. Coordinate the 65,534-entry ZIP32 cap with FTP Sync and test real cross-app round trips.
6. Run native computer-use import/export, replacement, cancellation, recovery, relaunch and
   accessibility checks against disposable roots after the UI exists.

Overall 3.0 readiness remains **IMPLEMENTING**. No final manual-testing notification is due.
