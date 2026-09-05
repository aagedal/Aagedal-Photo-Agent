# Plan-status rename identity and Known People cache continuation — 2026-09-05

## Scope and result

This continuation advances Phase 3.1 and release responsiveness/recovery work. The audit remains
at 66 of 75 checked substeps; the broader filesystem inventory and real-volume gates remain open.

`RenameIdentityPreparationService` serializes parent-symlink lookup and full destination
canonicalization away from MainActor, returning complete immutable dictionaries. Cancellation
before or during preparation prevents a partial snapshot from being published. Compare prepares
these facts asynchronously and applies them to its current coordinator, preserving newer viewport
and focus changes. Pending rename batches survive replaced/cancelled preparation, an uncaptured
replacement source triggers another preparation, and disappearance invalidates pending publication.

Analysis prepares identities after the filesystem commit, then merges path hints into the latest
case and revision values, preserving newer annotations and analyzer output. Workspace generation
prevents publication into a replacement workspace. Postcommit bookkeeping intentionally finishes
despite caller cancellation so the rename save gate cannot reopen with old path hints. Prepared
canonical relocation overloads avoid a second main-thread symlink lookup. Existing synchronous
compatibility APIs remain for non-UI callers and tests.

The Known People audit found two correctness prerequisites for its larger asynchronous migration.
`addPerson` now finishes cold-cache loading and any embedding migration before writing new person
or thumbnail data. This avoids discovering and appending the same UUID twice, and prevents a
pending migration from removing the newly added files. Import publication now merges each durable
prefix into the current cache instead of replacing it with a snapshot captured before suspension.
Concurrent additions, edits and deletions of other records survive success, partial failure and
cancellation. Duplicate UUIDs within an archive are filtered before commit, and cache modification
time cannot regress.

## Validation

New tests cover off-main identity preparation, cancellation before/during preparation, cold-cache
addition and migration order, and deterministic import interleaving with local CRUD under successful,
failed and cancelled completion. Existing atomic rename and real symlink-folder reconciliation tests
now exercise prepared identities. Two sub-agents implemented/reviewed independent slices.

Final validation:

- Serial unfiltered run: **2,075 tests in 237 suites passed**, zero failures, 68.468 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_21-47-49-+0200.xcresult`
in Xcode DerivedData. Full log: `/private/tmp/aagedal-rename-people-full.log`.
Repository validation log: `/private/tmp/aagedal-rename-people-repository.log`.
Automated results do not substitute for the manual checks below.

## Manual testing status

**User-reported pass (2026-09-05):** annotations survived renaming an image inside Analysis
and renaming an image outside Analysis. In both cases the user switched between Analysis and
Single view and observed that the annotation remained. This validates those two interaction paths;
it does not establish persistence across app relaunch or the additional volume/concurrency checks.


The Compare portion of this check failed in manual testing. The reported race and the corrected,
focused-pane test procedure are recorded in the [regression follow-up](comparison-rename-regression-validation-2026-09-05.md).
Test Compare and Analysis separately using copied photos:

1. In Compare, focus and rename each pane separately with File → Rename. Test the selected image
   separately in Analysis. Verify that the workspaces show the new names without
   missing-image placeholders, retain Compare zoom/pan, and retain Analysis annotations after reopening.
2. Repeat quick successive renames, including swapping names. During processing, change Compare zoom
   or replace a pane; switch or close Analysis. Verify that late work does not restore an old selection,
   overwrite the new viewport, lose annotations, or freeze navigation.
3. Repeat through a symlinked folder and, when available, a network or iCloud-backed test folder.
   Report macOS version, volume type, operation, and any pause, stale image, missing image or error.

The two Analysis annotation checks above are recorded as passed. Compare, rapid-rename and
volume-specific checks remain open. Thread Performance Checker and Instruments
measurements still need the broader existing performance protocol and representative large libraries.

## Remaining implementation and release gates

Known People database loading/reload still needs a complete serialized storage boundary shared with
mutations. Loading currently includes directory creation, legacy migration, verified embedding backup
and reset, conflict resolution/rewrite, tombstone cleanup and final assembly. Moving only reads off
MainActor would race those writes. The next complete migration should:

- Extract these filesystem transactions into a storage owner accepting a resolved root and captured
  migration policy, returning database, durable-write and migration evidence.
- Serialize local CRUD, remote changes, import commit, whole-store clearing and load/migration under
  that owner, including same-ID conflicts that this cache-publication fix does not solve.
- Make loading/reload and mutation callers await it; keep UI computed getters cache-only with explicit
  loading state, coalesce loads, and reject stale root/generation publication.
- Retain failure-injection coverage for migration backups, unavailable models, conflict merges,
  tombstones, corrupt files, mutation during loading, routing changes and postcommit cancellation.

Phase 3.1 also retains local SSD, network-volume, iCloud-placeholder, read-only-volume, large-library,
signpost and Thread Performance Checker evidence. Phase 3.2 retains the representative RAW/HDR
Instruments benchmark. Other release gates remain protected-release-branch enforcement, Known People
privacy/legal review, real FTP/FTPS/SFTP drills, accessibility/keyboard validation, and the AuraFace
model-omitted release candidate plus supported-macOS production-server lifecycle drills. Production
model publication was already completed; this continuation does not claim those external passes.
