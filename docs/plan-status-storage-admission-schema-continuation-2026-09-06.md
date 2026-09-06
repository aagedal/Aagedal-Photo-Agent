# Storage admission and schema compatibility continuation — 2026-09-06

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete; the delivery plan remains **119 of 142**. These changes close
specific storage races and filesystem paths, not the complete storage or device gates.

- Known People reserves archive destination record and thumbnail paths through commit and
  publication. Conflicting synchronous local mutations return a retryable error before their
  side effects; unrelated records remain editable. Database clearing is refused at the active
  import root. Void thumbnail deletion requests run after archive completion at their captured
  root, including cancellation. Composite embedding mutations preflight thumbnail admission
  before updating their person record.
- Keyword durable-write notifications carry destination identity. Old-root commits invalidate
  the current list without publishing stale entries or suppressing the owner's reload. Deferred
  notification consumers recheck the route before installation, and approved/Quick List owners
  reload instead of directly installing a superseded destination's payload.
- Atomic JSON storage performs nested-format compatibility checks inside its serialized actor,
  against the same bytes used for decoding and replacement. Future nested documents are never
  treated as corruption eligible for fallback. Delivery workflow checkpoints, receipts, deadline
  profiles, and rename recipes use this boundary instead of separate preflight filesystem reads.
  Direct saves protect newer-format backups even when their primary is missing or corrupt.
  Compatibility errors leave primary and backup bytes intact; ordinary corrupt-primary recovery
  remains supported.
- Keyword editor file import reads and parses through the existing serialized import service,
  with task cancellation and request identity guarding publication and subsequent persistence.
  Editor mutations require a successfully loaded or confirmed-missing baseline at the current
  destination, preserving unreadable lists and rejecting replaced-root baselines.

Two sub-agents implemented Known People admission and keyword routing/import; the parent
implemented atomic schema compatibility, reviewed the integrations, and maintained the plans.

## Validation

The integrated full run passed **2,175 tests in 253 suites**, zero failures, in
71.706 seconds of Swift Testing execution. Its production sources match this continuation.
The subsequent removal of one source-text-only assertion leaves the behavioral tests intact.
`scripts/ci/validate_repository.sh` and `git diff --check` passed. The earlier focused selection
passed 90 tests in seven suites before the final backup/import additions.

Logs: `/private/tmp/aagedal-storage-admission-full.log`,
`/private/tmp/aagedal-storage-admission-focused.log`, and
`/private/tmp/aagedal-storage-admission-repository.log`.

A final rebuild after removing the source-text assertion succeeded, but its repeat test run
stalled before test execution. A process sample showed XCTest waiting in
`_prepareTestConfigurationAndIDESession`; the run was stopped. A `test-without-building` retry
also stalled after host launch without executing tests and was stopped. Its log is
`/private/tmp/aagedal-storage-admission-final-retry.log`. Neither interrupted repeat is
counted as a passing run; the 2,175-test result above is the completed integrated run.
Editor baseline admission was reviewed in source; interactive load-failure/retry and
storage-switch checks remain manual.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

New regressions use existing registered test files. They cover normal/cancelled Known People
import admission, deferred deletion, successful retry, unrelated-record preservation, keyword
route publication, actor-side nested-schema rejection, direct-save refusal, and preservation of
future-only backups with missing/corrupt primaries. Existing repository suites cover schema
migration and nested future-version recovery. An initial integration build rejected capture of a
non-Sendable notification in test assertions; tests now extract typed Sendable payloads before
the MainActor assertion closure. Xcode validation uses the existing package/compiler caches.

## Remaining work

1. **Known People storage owner:** local admission reservations are scoped to one service
   instance. Database loading, migrations, remote tombstone handling, clearing, and local CRUD
   still need one asynchronous serialized owner shared with archives; UI getters must become
   cache-only. Other instances and external writers are outside these reservations. A route
   switch prevents stale publication but cannot preempt filesystem calls already entered.
2. **Keyword storage owner:** resolve uncached iCloud roots asynchronously before editor reads
   and mutation admission, retire synchronous store APIs, and serialize route reconciliation
   with all read/merge/write mutations. Completed writes can still belong to a previous root;
   the new guard protects current cache publication, not destination selection or reconciliation.
   Synchronous legacy archive helpers remain but current sheets use actor-backed paths.
3. **Atomic JSON coordination:** each store instance serializes its own operations. Independent
   instances or external processes can still change files after compatibility checks; these
   changes do not introduce cross-process transactions.
4. **Measurements and manual checks:** complete SSD/network/iCloud-placeholder/read-only/
   large-folder responsiveness and Thread Performance Checker evidence; benchmark representative
   RAW/HDR navigation, comparison, editing, and export with Instruments on agreed hardware.
5. **Release and external gates:** protected-branch CI enforcement; Known People privacy/legal
   review; FTP/FTPS/SFTP real-server failure drills; VoiceOver, keyboard, IME, contrast,
   Reduce Motion, and multi-display checks; model-omitted AuraFace candidate, package-size
   measurement, and supported-macOS production-server install/offline/update/rollback/removal/
   relaunch/interrupted-or-corrupt-download drills. Production model publication is already done.
6. **Delivery-only gates:** long-running GPU/cancellation, permission/launch, upgrade/downgrade,
   runtime privacy, backup/restore/crash, and signed release validation remain. Automated schema
   regressions do not satisfy the real upgrade/downgrade matrix. The conditional AI-origin
   analyzer still requires model/license/corpus decisions and product approval.
