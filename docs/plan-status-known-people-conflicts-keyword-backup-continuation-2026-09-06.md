# Known People conflicts and keyword backup continuation — 2026-09-06

## Scope

This continuation advances the audit's preservation and Phase 3.1 filesystem work and
delivery Phase 12. The audit remains **66 of 75** complete: the complete serialized
storage migration and real-volume/manual exit gates remain open.

Known People conflict resolution now requires readable current and conflict records with
the filename's person identity before writing a merge. Any invalid input preserves every
version. A failed write leaves versions unresolved and the caller displays the durable
current record. After a successful write, cleanup touches only the captured versions, so
new conflicts arriving during the write survive. Ordinary person loads also reject
mismatched identities and retain original bytes using the existing corruption backup path.
These changes preserve data but do not move conflict handling off MainActor.

Remote Known People updates now require the active library's exact record or thumbnail
parent directory and a UUID filename. Old roots, similarly named siblings, nested files,
and misplaced extensions are rejected before application. The watcher now downloads and
forwards thumbnail changes as well as records. Remote thumbnails and deletions invalidate
cached images and superseded reads, including when thumbnails load before the database.
Thumbnail content invalidation uses its own revision rather than changing the storage
generation. A cold database remains cold until its normal complete load.

Keyword backup source reads and recovery scans now run on the backup filesystem actor.
Cancellation after a source read prevents snapshot writes; recovery distinguishes missing
or empty lists from unreadable lists, and checks request, root, and version before publishing.
Completed iCloud toggles install their already-resolved destination in the keyword store,
avoiding an immediate second ubiquity lookup during notifications.

Two sub-agents handled keyword backup/routing and conflict preservation. Parent integration
handled remote update routing, thumbnail races, and cold-cache behavior.

## Validation

Final integrated validation:

- Serial unfiltered app/test run: **2,135 tests in 245 suites passed**, zero failures,
  64.411 seconds of test execution.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.06_11-52-57-+0200.xcresult`
in Xcode DerivedData. Logs: `/private/tmp/aagedal-conflicts-backup-verified.log` and
`/private/tmp/aagedal-conflicts-backup-repository.log`.

Commands:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

The initial sandboxed Xcode attempt could not write compiler/package caches. The retry
used authorized cache access. The first focused Known People selection passed 24 tests;
subsequent integration added conflict, malformed-identity, backup, and cold-cache coverage.
The first full run found one outdated source contract expecting the old routing call;
it now requires publication of the committed root. The final run also includes the last
cold-database remote-deletion regression cases.
Automated filesystem and conflict fixtures do not establish actual iCloud or device behavior.

## Remaining work

- Known People still needs a single serialized owner for loading/reloading, person CRUD,
  migrations, conflicts, remote apply, thumbnail writes/deletions, imports, and clearing,
  followed by cache-only UI database getters and storage-generation publication guards.
- KeywordListsStore's uncached `rootURL` still calls the ubiquity-container resolver
  synchronously. Startup and temporarily unavailable cloud routes need asynchronous
  resolution and explicit publication. Production URL consumers include ApprovedListService,
  StructuredKeywordService, KeywordListEditor, SettingsViewModel, MetadataPanel, keyword
  archive request/inventory preparation, and backup snapshot/restore/recovery preparation.
  Their content I/O already uses asynchronous services; this remaining root lookup can block.
- Synchronous keyword store content APIs and archive export/import helpers remain as
  compatibility/test paths. The production archive sheets already use async inventory and
  commit APIs. Complete the inventory before removing or changing those compatibility APIs.
- Validate iCloud placeholders, slow providers, root toggles/retries, thumbnail refresh,
  conflict cleanup failures, and cross-device updates on real cloud storage.
- Measure SSD/network/iCloud/read-only/large-folder responsiveness with Thread Performance
  Checker, and representative large RAW/HDR navigation, edit, comparison, and export with
  Instruments on supported hardware.
- Enforce release-branch CI, obtain the focused Known People privacy/legal review, run
  real FTP/FTPS/SFTP failure drills and the accessibility/keyboard matrix, and build the
  model-omitted AuraFace release candidate for supported-macOS production-server lifecycle
  checks. Production model publication is already complete.
- Delivery Phase 12 also retains GPU/long-running cancellation, permission/launch,
  upgrade/downgrade/newer-schema, runtime privacy, backup/restore/crash, and signed release gates.
