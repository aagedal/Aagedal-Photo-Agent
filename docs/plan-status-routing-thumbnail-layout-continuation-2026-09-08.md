# Routing, thumbnail preparation, and export layout — 2026-09-08

## Scope

This continuation advances audit Phase 3.1, delivery Phase 12, and the deferred
Advanced Export layout candidate. The audit remains **66 of 75** and delivery
remains **119 of 142** complete. Broad storage and manual/device/release gates
remain open.

- Structured keyword imports resolve their destination after external source reading.
  A storage switch during that read therefore uses the current destination. Stale-root
  load results and failures trigger a current-root reload. Storage-resolution failures
  clear stale trees and disable editing until a successful retry.
- Known People prepares replacement thumbnail JPEG bytes on its serialized thumbnail
  worker. Cancellation and storage/content revisions guard publication; embedding removal
  reloads the current person after preparation and preserves intervening peer edits.
  Normal record writes and thumbnail mutations still run synchronously on MainActor.
- Advanced Export uses its hosting window's usable display area, observes screen changes,
  and bounds its sheet size. Narrow displays scroll comparison columns and their headings
  together. The loupe uses SwiftUI's display scale and refreshes its crops when the required
  pixel size changes.

Three sub-agents implemented these independent changes. The parent reviewed integration,
requested explicit routing-failure handling and production thumbnail conversion coverage,
corrected a misplaced loupe task identifier during review, guarded cancelled loupe errors
from replacing newer state, and ran integrated validation.

Implementation commits: `716dc6a` (keyword routing), `222c55d` (thumbnail preparation),
and `0194663` (export layout).

## Validation

The application/test build and unfiltered suite passed **2,228 tests in 259 suites**,
zero failures, in **73.506 seconds** of Swift Testing execution. This includes four
layout policy tests, three structured routing/recovery regressions, and four thumbnail
preparation/removal regression tests with valid/corrupt and peer-edit/cancellation cases.
The existing storage-root replacement test also passed.

A subsequent review added the guard suppressing ordinary errors from cancelled loupe
requests. The final application/test rebuild and focused run passed **50 tests in 3 suites**,
zero failures, in **6.986 seconds**. This validates the final source revision.

Repository validation passed. The initial sandboxed Xcode invocation could not write
compiler/package caches; approved validation used the existing caches. Parser checks
passed; an agent's standalone typecheck was blocked by the CLI compiler/SDK mismatch,
which the successful Xcode build supersedes. Automated evidence does not establish
physical display behavior, real-volume performance, or server/release readiness.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:'Aagedal Photo Agent Tests/AdvancedExportLayoutTests' \
  -only-testing:'Aagedal Photo Agent Tests/KnownPeopleServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/StructuredKeywordRoutePublicationTests'
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-improvements-2026-09-08-tests.log`,
`/private/tmp/aagedal-improvements-2026-09-08-final-tests.log`, and
`/private/tmp/aagedal-improvements-2026-09-08-repository.log`.

## Remaining work

1. **Storage ownership:** Known People root/database loading, CRUD, migrations,
   conflict/tombstone maintenance, clearing, ordinary thumbnail mutations, and deferred
   event replay retain synchronous MainActor work. Imports use a process-wide FIFO.
   Keyword routing and preference publication remain separate; a route change between
   final destination resolution and actor commit can still write to a captured older root.
   Snapshot copying occupies the keyword actor, and in-process serialization does not
   provide cross-process/cloud-device atomicity.
2. **Performance and interaction:** agree hardware tiers and budgets; gather local,
   network, iCloud-placeholder, read-only, and large-folder measurements, Thread Performance
   Checker/RAW/HDR Instruments evidence, GPU/cancellation stress, accessibility, IME,
   localization, permissions, and runtime privacy results. Manually validate Advanced Export
   on small displays and during display/scale changes, including aligned scrolling and actions.
3. **Recovery and external gates:** hands-on upgrade/downgrade, backup/restore and
   crash-interruption drills; protected release-branch CI enforcement; Known People
   privacy/legal review; real FTP/FTPS/SFTP certificate/host-key/failure drills.
4. **Model and release:** supported-macOS production-server installation, offline,
   update, rollback, removal, relaunch, interrupted/corrupt downloads, and signed/notarized
   distribution. The unsigned model-free candidate remains tied to its earlier source revision.
   Conditional AI-origin analysis needs model/license/corpus decisions and product approval.
5. **Other deferred candidates:** undoable template deletion, Workspace/Layout navigation
   separation and Metadata Review exit, multilingual strings/layout work if planned, and
   a broader forced-cast audit.
