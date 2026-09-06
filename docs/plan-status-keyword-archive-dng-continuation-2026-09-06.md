# Keyword archive and DNG discovery continuation — 2026-09-06

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. The audit remains
**66 of 75** complete; the delivery plan remains **119 of 142**. These bounded changes do
not close the broad storage migration or manual/device gates.

- Keyword storage reconciliation propagates flat-list read failures instead of replacing
  unreadable source or destination content with an empty merge input. Cloud placeholders
  remain intact. Earlier successful per-list merges remain durable; retry preserves union order.
- Keyword archive import rejects failed source reads and failed append-destination reads,
  preserving the affected destination and reporting any earlier durable commits.
- Known People archive preparation accepts a root `people.json` with thumbnail folders;
  otherwise it requires exactly one wrapper containing `people.json`. Unrelated folders no
  longer determine selection. Ambiguous, missing, or corrupt payloads fail before destination
  writes. Discovery checks cancellation around each filesystem probe and cleans up staging.
- Adobe DNG Converter discovery moves Launch Services lookup and executable probes to a
  serialized actor. Browser context menus use a cached availability snapshot and schedule
  refresh; unknown availability allows the archive action to perform its fresh asynchronous
  preflight. Cancellation and superseded refreshes cannot publish unavailable/stale cache state.
- `TODO.md` now reflects the recorded 2026-09-01 production model publication. This session
  did not repeat production-server validation.

Sub-agents implemented the three independent code areas; the parent reviewed failure and
cancellation behavior, identified the additional archive read-failure path, integrated the
changes, and maintained the plans.

## Validation

Final frozen-source serial run: **2,155 tests in 249 suites passed**, zero failures,
66.613 seconds of Swift Testing execution. `scripts/ci/validate_repository.sh` and
`git diff --check` passed. Logs are `/private/tmp/aagedal-improvement-storage-final.log`
and `/private/tmp/aagedal-improvement-storage-repository.log`.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Regression coverage includes source/destination placeholder and directory read failures,
ordered union and retry after a durable prefix, six real keyword ZIP failure fixtures through
both import APIs, six Known People archive layouts, four archive discovery cancellation stages,
and six DNG lookup/cache/cancellation tests. The DNG test file is explicitly included in the
Xcode test target.

The initial combined run exposed a directory-URL comparison error in the new cancellation
fixture. The fixture now compares standardized paths. Integration review also caught missing
Xcode target membership for the new DNG test file; the final run includes it. Initial isolated
build attempts encountered restricted compiler caches and unavailable dependency networking;
combined validation uses the existing package cache with authorized Xcode cache access.

## Remaining work

1. **Known People storage ownership:** use one serialized owner for database load/reload,
   JSON CRUD, migration, conflicts, remote apply, archive commits, thumbnails, and clearing.
   Current synchronous cache getters can load files. The separate archive actor still does
   not serialize its writes with local CRUD. Fixing archive layout does not resolve that race.
2. **Keyword storage ownership and routing:** retire synchronous compatibility APIs and make
   root acquisition asynchronous before both editor loading and mutation admission. Fence
   writes against route changes. Read-failure handling does not make read/merge/write atomic
   against concurrent edits or make whole-tree reconciliation transactional.
3. **Responsiveness and hardware evidence:** finish the filesystem inventory and collect
   local SSD, network, iCloud-placeholder, read-only, and large-folder measurements with
   Thread Performance Checker. Run representative RAW/HDR navigation/edit/export and two-RAW
   comparison Instruments benchmarks on agreed hardware tiers. DNG menu availability updates
   on the next menu opening; real external-volume behavior remains unmeasured.
4. **Release and external reviews:** enforce CI on the protected release branch; obtain the
   focused Known People privacy/legal review; run FTP/FTPS/SFTP failure drills and the
   VoiceOver, keyboard, IME, contrast, Reduce Motion, and multi-display matrix.
5. **AuraFace release validation:** build the model-omitted candidate, measure package-size
   reduction, and exercise production-server install, offline, update, rollback, removal,
   relaunch, and interrupted/corrupt-download behavior on every supported macOS tier.
6. **Delivery-only gates:** GPU and long-running cancellation, permission/launch behavior,
   upgrade/downgrade/newer-schema handling, runtime privacy, backup/restore/crash drills, and
   signed release steps remain open. The conditional AI-origin analyzer still requires a
   model/license/corpus decision and explicit product approval before implementation.
