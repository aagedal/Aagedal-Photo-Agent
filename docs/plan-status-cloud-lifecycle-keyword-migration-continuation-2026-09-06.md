# Cloud watcher lifecycle and keyword migration continuation — 2026-09-06

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete; the broad filesystem inventory and real-volume gates remain open.

All four cloud watchers bind queued notifications to the query generation that created them.
Replacing a root or stopping monitoring invalidates old callbacks before they can read another
query. Teams and Watermark explicit-root refreshes cancel pending container resolution and replace
an existing query when its root changes. Known People cleanup clears pending refreshes and changes
even without an active query. Keyword-list routing hands its prepared destination directly to the
watcher, avoiding a repeated container lookup and allowing root replacement.

Legacy keyword-list migration captures preference inputs on MainActor and resolves bookmarks,
reads/parses sources, writes, and verifies results on a serialized actor. Each batch returns verified,
durable-written, failed, and cancelled evidence. Existing managed destinations, including iCloud
placeholders and edits arriving during source reads, take precedence: migration seeds only missing
files under one coordinated existence-check/write transaction. Legacy bookmark bytes remain as
recovery evidence. Active-route durable writes invalidate caches; stale route/version/bookmark
results cannot install completion stamps. Startup awaits this dependency before subsequent work.

## Validation

- Serial unfiltered app/test run: **2,112 tests in 240 suites passed**, zero failures,
  66.039 seconds of test execution.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

The regression coverage exercises root replacement/idempotence, cancelled suspended lookups, actual
queued metadata-query callbacks across replacement/disable, active callback admission, migration
pre-cancellation/read cancellation, verified writes retained after cancellation, read-back failure with
continued batch progress, unavailable bookmarks, a newer destination created during source reads,
and placeholder preservation. Existing retry tests use an isolated store and still verify per-source
completion and retained bookmarks. Two sub-agents implemented/reviewed the independent watcher and
migration slices; the parent integrated and validated them.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.06_00-28-18-+0200.xcresult`
in Xcode DerivedData. Logs: `/private/tmp/aagedal-cloud-lifecycle-full.log` and
`/private/tmp/aagedal-cloud-lifecycle-repository.log`.
The initial sandboxed test attempt could not write Xcode/compiler caches. The authorized retry
exposed a test-double actor-isolation compile error, corrected before the successful full run.
Automated fixtures do not establish real iCloud or device performance behavior.

## Remaining work

- Finish Known People load/reload, migration, conflict resolution, CRUD, remote changes, and clearing
  behind one serialized storage owner, with cache-only UI getters and generation guards.
- Finish keyword-list store routing, directory preparation, synchronous reads/writes, and notification
  observer filesystem migration. This change covers legacy migration, not the whole store.
- Audit already-admitted remote-apply operations across root replacement. Query generations protect
  callback admission; they do not undo a store transaction that already began.
- Record real iCloud placeholder, slow-provider, toggle/retry, and cross-device refresh drills.
- Record SSD/network/iCloud/read-only/large-library responsiveness and Thread Performance Checker
  evidence, plus representative RAW/HDR navigation/edit/export Instruments measurements.
- Complete protected release-branch enforcement, Known People privacy/legal review, real
  FTP/FTPS/SFTP failure drills, accessibility/keyboard checks, and the model-omitted AuraFace
  release candidate with production-server lifecycle checks on supported macOS versions.
