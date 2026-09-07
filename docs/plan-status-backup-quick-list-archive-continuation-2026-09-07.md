# Backup, Quick List, and archive continuation — 2026-09-07

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete and the delivery plan remains **119 of 142**. These are specific
storage and preservation improvements; the broad storage and external gates remain open.

- Settings and Metadata Panel Quick Lists resolve storage asynchronously for cache loads,
  imports, edits, and deletion. Cache-only notification comparisons and request, route,
  and version checks reject obsolete publication after cancellation or storage changes.
- Archive inventory, import preview, and import requests resolve one asynchronous root,
  then capture immutable paths. Storage changes reject obsolete inventory and preview
  publication; durable imports still notify observers without advertising old-root data.
- Backup snapshots, restore, and recovery checks resolve storage asynchronously. Unreadable
  and invalid UTF-8 files have explicit unavailable states and unknown entry counts. Failed
  directory enumeration is distinct from a missing backup directory. The UI explains failures,
  offers Reload, and disables unavailable restores. Recovery requires a readable nonempty backup.
- Retention preserves unavailable versions and excludes them from the minimum readable history.
  Inspection observes cancellation between files and before creating directories.
- Restore saves the exact current destination bytes to a unique local backup before replacement,
  including empty or damaged text. Failed destination reads or safety-backup writes abort replacement.
  Source validation occurs first; cancellation is checked between operations.
- Known People deletion markers must match their filename identity before their payload can
  suppress a person or qualify for expiry. Mismatched marker bytes remain intact, suppress their
  filename identity conservatively, and cannot delete an unrelated person named by the payload.

Three sub-agents implemented Quick List routing, archive routing, and backup integrity/UI/tests.
The parent integrated backup routing and pre-restore preservation, fixed deletion-marker identity,
reviewed the changes, and maintained the plans.

## Validation

The first build found an invalid enum case in a new archive test; it was corrected.
The first complete integrated run built successfully and ran **2,207 tests in 257 suites**,
with one failing new backup-inventory assertion comparing differently represented file URLs.
All other tests passed, including restore preservation, cancellation, routing, and deletion-marker identity.
A second full run passed the readable-file assertions but exposed the equivalent alias
problem for the dangling symbolic link. The test now selects unique filenames within its isolated
directory; it still checks every availability state, text value, count, and byte count.

The final application/test build succeeded and the unfiltered suite passed **2,207 tests
in 257 suites**, zero failures, in **64.484 seconds** of Swift Testing execution.

`scripts/ci/validate_repository.sh` and `git diff --check` passed. These are automated
regressions, not interactive iCloud, device, recovery, or accessibility evidence.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-backup-routing-full.log` (initial compile),
`/private/tmp/aagedal-backup-routing-final.log` (first complete suite),
`/private/tmp/aagedal-backup-routing-verified.log` (second complete suite),
`/private/tmp/aagedal-backup-routing-complete.log` (final suite), and
`/private/tmp/aagedal-backup-routing-repository.log`. Xcode uses existing package/compiler caches.

## Remaining work

1. **Known People storage ownership:** database loading, migrations, tombstones, clearing,
   local CRUD, and deferred remote/deletion replay still need a shared asynchronous serialized
   owner and cache-only UI getters. Archive reservations remain service-instance scoped.
2. **Keyword storage ownership:** synchronous compatibility APIs remain in the store and archive.
   Route reconciliation and all read/merge/write mutations need a shared serialization boundary.
   Already-entered filesystem work can still commit at its captured root; publication guards
   protect the active cache. Restore's read/backup/write sequence is serialized within its actor,
   but is not an atomic transaction with other actors, processes, or cloud devices.
3. **Performance evidence:** local SSD/network/iCloud-placeholder/read-only/large-folder checks,
   Thread Performance Checker, agreed hardware/budgets, RAW/HDR Instruments benchmarks, and
   long-running GPU/cancellation validation.
4. **Manual and external gates:** protected-release-branch CI enforcement; Known People privacy/legal
   review; FTP/FTPS/SFTP failure drills; accessibility, IME, contrast, Reduce Motion, localization,
   multi-display and source-permission checks; runtime privacy; upgrade/downgrade, backup/restore,
   and crash-interruption drills.
5. **Model and release gates:** model-omitted AuraFace candidate and measured package reduction;
   supported-macOS production-server install/offline/update/rollback/removal/relaunch/interrupted
   or corrupt download drills; signed release packaging and distribution. Model publication is
   complete. The conditional AI-origin analyzer still needs model/license/corpus decisions and
   explicit product approval.
