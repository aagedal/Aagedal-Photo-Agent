# Database coherence and archive staging continuation — 2026-09-07

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete and delivery remains **119 of 142**. Broad async storage,
manual, hardware, and distribution gates remain open.

- Known People durable record writes, deletions, import prefixes, and resets invalidate
  same-root peer databases and derived matching caches. Accepted remote record events also
  invalidate peers when the receiving service has no loaded database. Unresolved services
  remain cold, unrelated roots remain untouched, and import admission/storage revisions
  are preserved. Updating a person reloads an invalidated database before checking identity.
- Removed the synchronous keyword-store read/write/delete and blocking root compatibility
  APIs. Their test callers now use async production persistence services through test-only
  fixture helpers. Store tests use isolated task-local directories.
- Archive transport import/export entry points and injected transaction closures carry the
  shared filesystem actor isolation at compile time. Private import extraction and cleanup
  run on a separate preparation actor; the shared actor retains each uninterrupted managed-list
  read/merge/write batch. Preparation failure/cancellation removes staging without changing
  destinations; durable commit evidence survives later cancellation. The preview transport
  helper is file-private.

Two sub-agents implemented peer coherence and keyword compatibility removal. The parent
implemented archive isolation/staging, reviewed integration, and owns integrated validation.

## Validation

The final application/test build succeeded and the unfiltered suite passed **2,216 tests
in 258 suites**, zero failures, in **71.368 seconds** of Swift Testing execution.
This includes same-root CRUD/cache isolation, the existing 16-case deferred deletion matrix,
and the new success/cancellation archive staging regression. While extraction is blocked,
real managed-list edits and inventory complete; import preserves the concurrent edit and
both success and cancellation remove private staging.

The first build identified a throwing async test-macro inference issue, fixed by awaiting the
fixture read before its assertion. The next full run exposed six thumbnail assertions in the
existing deferred remote-deletion matrix: database invalidation made replay receivers cold.
Cold JSON record events now invalidate thumbnails and pending reads conservatively, without
forcing a database load. The new staging suite was moved into the explicitly included archive
test file before the final successful build/run.

Repository validation and `git diff --check` passed. Initial sandboxed Xcode package resolution
could not write compiler caches; approved builds used the existing caches. These automated
checks do not replace manual, real-volume, device, or production-server evidence.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-storage-coherence-tests.log` (initial build),
`/private/tmp/aagedal-storage-coherence-final-tests.log` (deferred-deletion regression),
`/private/tmp/aagedal-storage-coherence-verified-tests.log` (successful final suite), and
`/private/tmp/aagedal-storage-coherence-final-repository.log` (repository validation).

## Remaining work

1. **Known People async ownership:** root resolution, database loading, ordinary CRUD,
   conflict/tombstone maintenance, migrations, clearing, and deferred replay still include
   synchronous MainActor filesystem work. Peer caches now invalidate, but their next read
   still performs a synchronous reload. Import admission remains a process-wide FIFO.
2. **Keyword routing and transactions:** routing reconciliation and MainActor preference/cache
   publication remain separate; captured requests can commit to an older root. Export staging
   and compression still occupy the shared actor. In-process serialization does not provide
   cross-process/cloud-device atomicity.
3. **Performance and interaction:** agree hardware and budgets; measure local/network/iCloud-
   placeholder/read-only/large-folder responsiveness; collect Thread Performance Checker,
   RAW/HDR Instruments, long-running GPU/cancellation, multi-display, accessibility, IME,
   localization, contrast, Reduce Motion, permissions, and runtime privacy evidence.
4. **Recovery and external gates:** real upgrade/downgrade, backup/restore, crash-interruption,
   protected release-branch CI, Known People privacy/legal review, and real FTP/FTPS/SFTP
   certificate, host-key, and failure drills.
5. **Model and release gates:** supported-macOS production-server install/offline/update/
   rollback/removal/relaunch/interrupted/corrupt-download drills and signed/notarized distribution.
   The previous unsigned model-free candidate/size evidence remains tied to its recorded
   source revision. The conditional AI-origin analyzer requires model/license/corpus decisions
   and explicit product approval.
