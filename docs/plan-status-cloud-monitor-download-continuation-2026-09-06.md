# Plan-status cloud monitoring and download continuation — 2026-09-06

## Scope and result

This continuation advances Phase 3.1 and Phase 12 responsiveness. The audit remains at
**66 of 75** completed substeps; the full filesystem inventory and real-volume exit gates remain open.

Teams, Known People, Watermarks, and keyword lists now initiate iCloud placeholder downloads
through `CloudDownloadService`. Each coordinator owns a serialized service and tracked tasks;
stopping monitoring cancels queued work before the next Foundation request. Batches retain order,
deduplicate URLs, continue after individual failures, and return immutable attempted/failed URL
and cancellation evidence. Privacy-safe signposts report counts only. Foundation requests already
entered cannot be preempted, and initiation does not establish completed file download.

Keyword-list monitoring now resolves and creates its cloud directory through the existing routing
actor, sharing its executor with route reconciliation. Query callbacks reuse the captured root.
Cancellation before resolution prevents access; cancellation during preparation rejects publication;
directory failure prevents query startup and logs a privacy-safe error. This removes the prior
MainActor container lookup and coordinated directory creation from the watcher. Keyword-list
updates request all matching placeholders instead of stopping at the first matching file. All four
watchers require a directory separator when filtering paths, excluding similarly named sibling folders.

A sub-agent generalized the download service, integrated Known People and Watermarks, and reviewed
cancellation and directory filtering. The parent integrated keyword-list setup and download routing.

## Validation

The shared service tests cover off-main execution, serialized overlapping batches, order and
deduplication, per-file failures, accepted file types, pre-cancellation, and cancellation during
successful and failed non-preemptible requests. Parameterized source contracts cover all four
coordinators. Four new keyword monitoring tests cover off-main resolution/directory preparation,
unavailable roots, directory errors, cancellation before and during setup, and watcher delegation.
Tests use existing registered test sources.

Final frozen-source validation:

- Serial unfiltered run: **2,098 tests in 238 suites passed**, zero failures, 65.330 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.06_00-00-26-+0200.xcresult`
in Xcode DerivedData. Automated evidence does not substitute for the real-cloud checks below.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-cloud-monitor-full.log` and
`/private/tmp/aagedal-cloud-monitor-repository.log`. The initial sandboxed Xcode attempt failed
because package/compiler caches were not writable; the retry uses authorized cache access.

## Remaining work

- Move Known People load/reload, migrations, conflict handling, local CRUD, remote changes, imports,
  and clearing behind one serialized storage owner, with cache-only UI getters and generation guards.
- Complete keyword-list store filesystem migration; this watcher change does not remove synchronous
  access elsewhere in the store or in notification observers.
- Review watcher root replacement and already-admitted remote-refresh lifetimes. Teams/Watermark
  `refresh(resolvedRoot:)` currently retains an existing query when a different root is supplied;
  remote apply operations already entered are governed by their stores, not download-task cancellation.
- Validate real iCloud placeholders, slow provider initiation, disable/re-enable, failed-directory
  retry, multi-file keyword downloads, and cross-device refresh. No real-cloud pass is claimed.
- Complete SSD/network/iCloud/read-only/large-library performance and Thread Performance Checker
  evidence, and the representative RAW/HDR Instruments benchmark.
- Complete release branch enforcement, Known People privacy/legal review, real FTP/FTPS/SFTP drills,
  accessibility/keyboard checks, and model-omitted AuraFace release-candidate and supported-macOS
  production-server lifecycle checks. Production model publication is already done.
