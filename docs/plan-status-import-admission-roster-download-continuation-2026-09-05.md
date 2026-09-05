# Plan-status import admission and Teams cloud downloads — 2026-09-05

## Scope and result

This continuation advances Phase 3.1. The audit remains at **66 of 75** completed substeps;
the complete filesystem inventory and real-volume exit gates remain open.

Known People archive imports now retain one FIFO admission slot from preparation through duplicate
filtering, durable commit, and cache publication. The archive actor already serialized filesystem
operations, but separate MainActor stages could otherwise admit an overlapping import before the
preceding import published its committed IDs. A queued request checks cancellation and its captured
storage revision before preparation. Every exit releases admission, including failure, cancellation,
and storage replacement. Cancellation while queued returns after the incumbent finishes; it does
not interrupt an admitted durable write. Existing partial-commit evidence and cache merging remain.
This is an import-only prerequisite, not the complete shared CRUD/load storage migration.

Teams iCloud download initiation now runs on a serialized `RosterCloudDownloadService` actor.
The coordinator captures URL batches and cancels outstanding tasks when monitoring stops. The actor
deduplicates each batch, continues after individual failures, and returns immutable attempted/failed
URL evidence. Cancellation stops before the next request and retains evidence for a Foundation call
that has already run. Privacy-safe signposts contain counts and cancellation only. Initiation evidence
does not mean the cloud file has finished downloading.

## Validation

Three import scenarios cover duplicate admission, queued cancellation, and storage revision changes,
including exact write/read counts, cache/reload agreement, and progress after rejected waiters.
Five Teams tests cover off-main access, order/deduplication, per-file failure, cancellation before and
during access, serialization of overlapping batches, and coordinator routing/cancellation contracts.
All tests use existing registered test sources. A sub-agent implemented the Teams slice, and a second
reviewed import admission and test scheduling.

Final validation:

- Serial unfiltered run: **2,091 tests in 238 suites passed**, zero failures, 66.185 seconds.
- `scripts/ci/validate_repository.sh`: passed.
- `git diff --check`: passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

Result bundle: `Test-Aagedal Photo Agent Tests-2026.09.05_23-47-46-+0200.xcresult`
in Xcode DerivedData. Full log: `/private/tmp/aagedal-import-roster-full.log`.
Repository validation log: `/private/tmp/aagedal-import-roster-repository.log`.

The initial sandboxed test attempt could not write Xcode/package caches. An authorized retry
compiled against overlapping app/test edits and failed to see the new Teams actor in the app module.
The final frozen-source unfiltered run rebuilt both targets and passed; neither earlier attempt
is counted as passing evidence.

## Remaining work

- Move Known People load/reload, migrations, conflict handling, local CRUD, remote changes, imports,
  and whole-store clearing behind one serialized storage owner. Same-ID CRUD/import races are still
  outside this import-only gate. UI getters need explicit loading and cache-only publication with
  root/generation validation. The detailed prerequisites remain in the
  [previous continuation](plan-status-rename-identity-known-people-cache-continuation-2026-09-05.md).
- Validate Teams download/refresh behavior on real iCloud placeholders, including stopping monitoring
  during slow initiation. Foundation calls already entered cannot be preempted.
- Complete SSD/network/iCloud/read-only/large-library performance and Thread Performance Checker
  evidence, plus the representative RAW/HDR Instruments benchmark.
- Complete protected-release-branch enforcement, Known People privacy/legal review, real FTP/FTPS/SFTP
  drills, accessibility/keyboard validation, and the model-omitted AuraFace release candidate and
  supported-macOS production-server lifecycle drills. Production model publication is already done.

No manual, real-server, or cross-device validation is claimed by these automated tests.
