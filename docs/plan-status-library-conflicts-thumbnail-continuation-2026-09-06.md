# Library conflicts and import thumbnails continuation — 2026-09-06

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete. The full storage-owner migration and real-volume/manual gates remain open.

Teams and Watermarks now preserve every conflict input when any current or captured version is
unreadable, corrupt, or belongs to another record. Ordinary loads also reject mismatched record IDs.
A failed replacement write cannot publish the proposed merge. After a durable write, cleanup targets
only the captured Foundation version handles, leaving later conflicts available for another load.
Cleanup failures retain durable write evidence. Cancellation before replacement prevents the write.
These changes preserve the existing latest-updated-record conflict policy.

Known People archive imports invalidate decoded thumbnail caches and suspended thumbnail reads from
actual committed thumbnail URLs. This includes partial imports where a thumbnail write succeeds before
person JSON persistence fails. Existing storage-generation validation rejects old-root publication.

Sub-agents implemented Known People thumbnail and Watermark conflict handling; the parent implemented
Teams conflict handling and integrated the changes. A third agent explored asynchronous keyword-root
resolution. Integration and independent review found that returning local storage while cloud resolution
was pending could send an early edit to local storage and later hide it on route publication. That
experimental change was removed before final validation. A safe migration requires asynchronous root
acquisition before both editor snapshot loading and mutation admission, with writes fenced against route
transitions; changing the path getter alone is insufficient.

## Validation

Final frozen-source validation:

- Serial unfiltered app/test run: **2,143 tests in 246 suites passed**, zero failures,
  59.578 seconds of Swift Testing execution.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.06_21-28-28-+0200.xcresult`
in Xcode DerivedData. Logs: `/private/tmp/aagedal-library-continuation-full.log`
and `/private/tmp/aagedal-library-continuation-repository.log`.

New parameterized regressions cover unreadable/corrupt/mismatched conflict inputs, ordinary record
identity mismatches, failed replacement writes, cleanup failures, conflicts arriving during a write,
and cancellation during conflict reads. Eight Known People cases cover cached and suspended person
and embedding thumbnails across complete and partially failed imports. The earlier four-suite focused
run passed 44 tests before final cancellation cases and removal of the experimental keyword change.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

The initial sandboxed focused build could not write compiler/package caches; the authorized retry
passed. The final run used authorized cache access. Existing unrelated StructuredKeyword test warnings
and the AppIntents metadata extraction warning remain. Automated fixtures do not establish real iCloud
conflict behavior, accessibility, or hardware performance.

## Remaining work

- Known People still needs one serialized storage owner across load/reload, person JSON CRUD,
  migration, conflict resolution, remote apply, archive imports, thumbnail writes/deletions, and
  clearing. Cache getters still trigger synchronous loading, and archive writes can race local CRUD.
- Complete the keyword store's synchronous compatibility API migration and the broader filesystem
  inventory. Confirm root changes, retry, and cross-device refresh with real iCloud providers.
- Capture local SSD, network, iCloud-placeholder, read-only, and large-folder responsiveness and
  Thread Performance Checker evidence. Run representative RAW/HDR navigation/edit/export and
  two-RAW comparison Instruments benchmarks on supported hardware.
- Enforce the required workflow on the protected release branch; obtain the focused Known People
  privacy/legal review; run FTP/FTPS/SFTP server-failure drills and the accessibility/keyboard matrix.
- Build the model-omitted AuraFace release candidate and run production-server install, offline,
  update, rollback, removal, relaunch, and interrupted/corrupt-download checks on supported macOS
  tiers. Production model publication is already complete.
- Delivery Phase 12 additionally retains GPU/long-running cancellation, permission/launch,
  upgrade/downgrade/newer-schema, runtime privacy, backup/restore/crash, and signed release gates.
