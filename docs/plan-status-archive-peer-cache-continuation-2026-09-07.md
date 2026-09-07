# Archive and peer-cache continuation — 2026-09-07

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete and delivery remains **119 of 142**. These changes do not close
the broader storage architecture or manual, hardware, and external validation gates.

- Keyword archive convenience import, export, and inspection now use the asynchronous
  services. Request builders require an explicitly resolved root. Duplicate synchronous
  archive import and inventory implementations are removed. Partial imports publish
  their durable prefix before propagating failure or cancellation.
- Unused direct keyword-store import helpers are removed; their import regression
  exercises the production Approved List import service.
- Known People uses weak service registration to invalidate same-root peer thumbnail
  caches and reject suspended reads after saves, deletions, archive commits, and resets.
  Accepted remote thumbnail and deletion/tombstone events also invalidate peer thumbnails. Cold peers are not resolved,
  unrelated roots are unaffected, and import invalidation follows durable evidence even
  when subsequent person writes fail or the importing instance changes storage.
- Known People storage-size scans distinguish missing storage from an invalid root,
  unreadable directory, failed entry metadata, or incomplete enumeration. An unavailable
  measurement preserves person/sample counts without advertising a partial or zero-byte
  total. Settings clears stale measurements while loading and offers an explicit retry.
  Scans retain cooperative cancellation and do not follow symbolic links.

Two sub-agents implemented archive boundaries and peer cache invalidation. The parent
implemented measurement failures and UI recovery, reviewed integration, and maintained
the plans and validation evidence. Implementation commit: `bdb7663`.

## Validation

The initial application/test build and unfiltered run passed **2,212 tests in 257
suites** in **74.798 seconds**. The follow-up run built all changes and exposed two
assertions in the new echo fixture: `Date.distantPast` is correctly treated as a
separate remote change, not an echo of a recent write. The fixture now uses the
supported missing-change-date recency path. No production behavior was changed to
accommodate that test correction.

The corrected final application/test build succeeded and the unfiltered suite passed
**2,212 tests in 257 suites**, zero failures, in **69.195 seconds** of Swift Testing
execution. This includes the unavailable/partial measurement regressions, archive
durable-prefix notifications, and immediate/deferred peer cache invalidation matrices.

Repository validation and whitespace checks passed. Initial sandboxed Xcode attempts
could not write compiler/package caches; approved builds use the existing caches.
Two sub-agent test attempts overlapped the parent build and stopped on Xcode's build
database lock; the parent owns all integrated validation. These automated checks are
not manual iCloud, real-device, privacy, recovery, or production-server evidence.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-archive-peer-full-tests.log` (initial successful suite),
`/private/tmp/aagedal-archive-peer-final-tests.log` (incorrect echo fixture),
`/private/tmp/aagedal-archive-peer-verified-tests.log` (corrected final suite), and
`/private/tmp/aagedal-archive-peer-final-repository.log` (repository validation).

## Remaining work

1. **Known People async database ownership:** root resolution, loading, ordinary CRUD,
   conflict/tombstone maintenance, migrations, clearing, and deferred replay still include
   synchronous MainActor filesystem work. Database cache coherence needs a shared owner;
   thumbnail invalidation alone does not synchronize peer person databases. Import admission
   remains a process-wide FIFO, including unrelated roots.
2. **Keyword compatibility and route publication:** synchronous store read/write/delete
   helpers remain, currently used by test fixtures and compatibility tests. Low-level archive
   transport helpers remain callable synchronously. Routing reconciliation and MainActor
   preference/cache publication are separate; captured requests can commit to an older root.
   Archive staging occupies the shared actor. In-process serialization does not provide
   cross-process or cloud-device atomicity.
3. **Performance and interaction:** agreed hardware and budgets; local/network/iCloud-placeholder/
   read-only/large-folder responsiveness; Thread Performance Checker and RAW/HDR Instruments
   evidence; long-running GPU/cancellation; multi-display, VoiceOver, keyboard access, IME,
   localization, contrast, Reduce Motion, source permissions, and runtime privacy checks.
4. **Recovery and external gates:** real upgrade/downgrade, backup/restore, and crash-interruption
   drills; protected release-branch CI enforcement; Known People privacy/legal review;
   real FTP/FTPS/SFTP certificate, host-key, and failure drills.
5. **Model and release gates:** supported-macOS production-server install, offline, update,
   rollback, removal, relaunch, and interrupted/corrupt download drills; signed/notarized
   packaging and distribution. The earlier unsigned model-free candidate and controlled
   size measurement remain recorded at their original source revision. The conditional
   AI-origin analyzer requires model/license/corpus decisions and explicit product approval.
