# Keyword routing and import preservation continuation — 2026-09-07

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete and the delivery plan remains **119 of 142**. These changes
close specific storage and publication gaps; they do not complete the broad storage,
measurement, device, or release gates.

- Keyword root resolution now crosses an asynchronous serialized service for the flat
  editor, Structured Keywords, Approved Lists, and legacy migration. Routing generations
  reject superseded container lookups, and cancellation prevents late cache installation.
  Flat editor saves re-resolve the destination before committing their loaded baseline.
  Notifications and migrated callers compare cached paths without another ubiquity lookup.
  Approved List owners invalidate observers even for superseded durable commits and accept
  other owners' identified notifications; old-root reads/deletions reload the current root.
- Managed keyword text must decode losslessly as UTF-8 before it can become an editor,
  append, routing, archive, backup, or migration baseline. Damaged source/destination bytes
  remain intact. Failed cache entries are identified separately from valid sibling lists.
  External selected-file imports retain their encoding fallback policy. The approved-list
  parser checks actual byte size as well as preflight size, rejecting a growing source
  before it replaces the managed destination.
- Cancellation during keyword existence probes is observed before a subsequent read,
  deletion, or missing-destination result. Cache cancellation preserves the exact prefix
  of fully processed lists.
- Known People archive admission probes record and tombstone destinations on the archive
  actor before thumbnail writes. Unreadable records and deleted identities are skipped
  instead of being treated as empty destinations. Only durable person commits publish.
- Remote Known People events affecting reserved import paths replay after cache publication,
  including cancelled imports. Replay bypasses self-write echo suppression from the later
  import commit. A JSON event with a live tombstone removes the person from both disk and
  the in-memory database, preserving deletion intent through reload.

Two sub-agents implemented keyword routing/managed archive reads and Known People/Approved
List integration. The parent implemented persistence cancellation and decoding, import size
validation, reviewed the integrations, and maintained the plans.

## Validation

The first focused persistence selection passed **20 tests in one suite**. The first
integrated run passed **2,187 tests in 254 suites**, zero failures, in 65.704 seconds
of Swift Testing execution. The final integrated run, including Approved List routing and
archive/backup decoding changes, passed **2,193 tests in 256 suites**, zero failures, in
68.499 seconds. Both full application/test builds succeeded.

`scripts/ci/validate_repository.sh` and `git diff --check` passed on the final changes.
New tests use existing registered test files and cover actor execution, suspended root lookup,
cancellation, occupied destinations, remote deletion during import, durable publication,
and byte preservation. These are automated regressions, not interactive iCloud/device evidence.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-storage-followup-focused.log`,
`/private/tmp/aagedal-storage-followup-full.log`,
`/private/tmp/aagedal-storage-followup-final.log`, and
`/private/tmp/aagedal-storage-followup-repository.log`.
Xcode validation uses the existing package/compiler caches.

## Remaining work

1. **Known People storage ownership:** database loading, migrations, tombstones, clearing,
   local CRUD, and deferred remote/deletion replay still contain synchronous MainActor work.
   They need one asynchronous serialized owner shared with archives and cache-only UI getters.
   Import reservations remain scoped to a service instance. Destination probes and subsequent
   writes are not an atomic cross-process or cross-device transaction.
2. **Keyword storage ownership:** migrate remaining Settings/Caption Quick List, backup/archive,
   and legacy convenience callers from synchronous root resolution. Serialize route
   reconciliation with every read/merge/write mutation, not just individual actor families.
   An already-entered filesystem call can still commit at an earlier captured root; publication
   guards protect the current cache. Backup inventory can still display invalid or unreadable
   text as empty, although restore validates before writing.
3. **Performance evidence:** finish local SSD/network/iCloud-placeholder/read-only/large-folder
   responsiveness and Thread Performance Checker checks. Agree target hardware and budgets,
   then record representative RAW/HDR navigation, comparison, edit, export, and memory behavior
   with Instruments, plus long-running GPU/cancellation validation.
4. **External and manual gates:** protected-release-branch CI enforcement; Known People
   privacy/legal review; real FTP/FTPS/SFTP failure drills; VoiceOver, keyboard, IME, contrast,
   Reduce Motion, localization, and multi-display checks; source permissions and launch;
   runtime privacy; real upgrade/downgrade, backup/restore, and crash-interruption drills.
5. **Model and release gates:** build the model-omitted AuraFace candidate, measure package
   size, and run supported-macOS production-server install/offline/update/rollback/removal/
   relaunch/interrupted-or-corrupt-download drills. Model publication is already complete.
   Signed release packaging and distribution remain gated. The conditional AI-origin analyzer
   still needs model/license/corpus decisions and explicit product approval.
