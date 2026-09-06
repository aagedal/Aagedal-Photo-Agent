# Storage generation and structured keyword continuation — 2026-09-06

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete: these changes do not close the complete filesystem inventory,
real-volume measurements, or external/manual gates.

Structured keyword initialization, notification reloads, saves, and deletion now use the
serialized keyword editor persistence service. Reads preserve indentation and return immutable
text/missing/cancellation results. Request identity and destination checks reject superseded
publication; editor-facing reload waits follow replacement generations to their settled snapshot.
The editor awaits its initial snapshot and its save, keeps Cancel available during loading, and
permits editing empty readable files while preventing saves after a failed read. Deletion errors
reach Settings. Constructing the keyword store and resolving test paths no longer create directories.

Teams and Watermarks bind mutations to a storage generation before their first suspension.
Replacing storage invalidates pending loads immediately; completed old-root writes retain their
durable evidence without changing the newly selected library's cache. Remote changes are filtered
against the active library directory. Known People thumbnail loads now reject local content
changes and cancellation before cache publication, and removing an embedding rejects a storage
switch while awaiting its representative thumbnail.

Three sub-agents implemented the independent slices. Parent integration reviewed storage-root
publication, notification ordering, and editor cancellation behavior. A separate asynchronous
Known People thumbnail cleanup actor was considered and omitted: serializing only deletion would
leave it racing with synchronous thumbnail writers. The complete storage-owner migration remains
necessary.

## Validation

Final frozen-source validation:

- Serial unfiltered app/test run: **2,125 tests in 244 suites passed**, zero failures,
  63.523 seconds of test execution.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.06_11-41-29-+0200.xcresult`
in Xcode DerivedData. Logs: `/private/tmp/aagedal-storage-continuation-verified.log`
and `/private/tmp/aagedal-storage-continuation-repository.log`.

Regression coverage includes structured text preservation/off-main execution, cancellation after
read and durable write, deletion failure/success, stale-route notification content, missing/readable
empty/unreadable snapshots, replacement reload ordering, and filesystem-free path resolution.
Blocked Teams upsert/deletion and Watermark import prove that old-root files and commit evidence
survive without repopulating replacement caches. Known People tests exercise four thumbnail
write/deletion interleavings and a storage switch during embedding removal.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

The first sandboxed build could not write Xcode/Swift caches and succeeded with authorized cache
access. The first unfiltered run was interrupted after a new Watermark test fixture omitted parent
directory creation before its gated write. The fixture now matches coordinated-write behavior;
gate waits are bounded and deferred release prevents a failure from stranding a worker. A subsequent
full run passed 2,124 tests in 243 suites before the final replacement-reload regression was added.
Automated fixtures do not establish real-cloud, accessibility, or device performance behavior.

## Remaining implementation and external gates

- Known People still needs a single serialized owner for load/reload, person JSON CRUD, migration,
  conflict resolution, remote apply, thumbnail writes/deletions, and clearing. Its current cache
  getters can still trigger synchronous loading. An isolated cleanup actor is insufficient because
  it must share ordering with writers and imports.
- Finish the keyword-list store's remaining synchronous compatibility APIs and root fallback
  resolution. Structured keyword production I/O is covered here; this is not a claim that every
  keyword archive or store entry point has migrated.
- Complete the remaining filesystem inventory and measure local SSD, network, iCloud placeholder,
  read-only, and large-folder responsiveness with Thread Performance Checker. Run real cloud
  placeholder, slow-provider, root-toggle/retry, and cross-device refresh drills.
- Benchmark representative large RAW/HDR navigation/edit/export and two-RAW comparison sessions
  with Instruments on supported hardware tiers.
- Enforce the required workflow on the protected release branch; obtain the focused Known People
  privacy/legal review; run FTP/FTPS/SFTP failure drills and the accessibility/keyboard matrix.
- Build the model-omitted AuraFace release candidate and run production-server install, offline,
  update, rollback, removal, relaunch, and interrupted/corrupt download checks on supported macOS
  versions. Production model publication is already complete.
- Delivery Phase 12 additionally retains GPU/long-running cancellation, permission/launch,
  upgrade/downgrade/newer-schema, runtime privacy, backup/restore/crash, and signed release gates.
