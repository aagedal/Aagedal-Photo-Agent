# Storage cleanup, repository and render workers — 2026-09-08

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. The broad storage-ownership
items and manual/device/release gates remain open.

- Settings clears Known People through the serialized archive worker. Whole-root
  reservations prevent same-root writes, including previously unknown person IDs,
  while recursive deletion is suspended. Even a failed recursive removal invalidates
  local and peer snapshots because it may have removed a prefix of the tree. Empty
  state is cached only after complete removal and directory recreation. An admitted,
  completed clear retains success if cancellation arrives during I/O; stale-root
  completion cannot publish into the replacement storage. Settings shows progress
  and protects newer feedback from an old clear-notice timer.
- Keyword history deletion has its own Dispatch worker. Retention admission spans
  scanning and deletion, preserving the readable-version minimum. Slow history
  unlinks no longer occupy managed keyword transactions. Immutable, uniquely named
  history files let a racing restore either read complete bytes or fail before
  changing its destination; deduplication remains conservative if history disappears.
- Match roster persistence and team roster exports retain Dispatch executors and
  caller task context. Deadline profile and rename recipe portable import/export
  paths do the same, reject cancellation before source reads and after staging,
  and remove unpromoted staging files. Cancelled queued operations release admission
  so subsequent edits can proceed.
- Analysis repository enumeration, provider writability probes and actor-isolated
  path comparisons retain a Dispatch executor. Tests preserve local/fallback routing
  and the root captured before a symlink is retargeted. Synchronous initializer root
  resolution and default Application Support preparation remain unchanged.
- Scope sidebar/PDF rendering, Comparison, Clean Feed, Develop source decoding,
  edited browser/prefetch previews, and presentation header/XMP reads use retained
  Dispatch executors. Scope callers await their original task instead of creating
  detached raster tasks. Cancellation is sampled around blocking work and before
  final publication; pixel behavior, output limits and existing GPU ownership remain.

Three sub-agents implemented Known People, repository and render slices. The parent
implemented retention deletion, registered tests, reviewed integration and maintained
validation/plans. Independent review checked retention admission, immutable history
and the two restore/unlink orderings. Review also corrected clear-after-cancellation
feedback and old notice-timer publication.

## Validation

The initial focused selection passed **126 tests in 7 suites**, zero failures, in
**14.483 seconds**. The final-source unfiltered run passed **2,338 tests in 273
suites**, zero failures, in **81.707 seconds**. This includes the final presentation
worker addition and the new suites housed in existing test files. Repository
validation and whitespace checks passed.

The final `.xcresult` in existing DerivedData is timestamped
`2026.09.08_22-22-16-+0200`.

Coverage exercises actual Dispatch isolation, task-local/priority retention,
pre-admission and queued cancellation, durable clear prefixes and cache invalidation,
storage changes and same-root reservations, cancelled export staging cleanup, worker
gate reuse, history deletion/restore overlap, and cancelled render publication.
Filesystem fixtures use temporary local files or injected provider boundaries.
They do not establish physical-volume, real-server, manual interaction or hardware
performance evidence.

The initial sandboxed Xcode invocation could not write existing compiler/package
caches; approved Xcode access resolved that restriction. Compilation identified an
invalid `nonisolated` modifier on a method with an `isolated` actor parameter. Removing
the redundant modifier preserved its worker isolation; runtime tests cover the hop.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-storage-render-focused.log`,
`/private/tmp/aagedal-storage-render-full-tests.log`, and
`/private/tmp/aagedal-storage-render-repository.log`.

Implementation commits: `e6aa75b` (rosters), `7f55c73` (Known People clear),
`6410e7b` (portable repositories), `2827c51` (retention and test registration),
`6fd16b7` (render workers), and `3217179` (analysis repository).

## Current-source unsigned Release candidate

A clean-source candidate built from `3217179d4d76922932bd61c0d3384c730cca1d20`, version
**3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS
27.0 (26A5425a). Model omission passed and all **79** ZIP payload
entries match the built application. The bundle contains 73 regular files totaling
145,423,346 bytes; the ZIP is 49,774,480 bytes.
ZIP SHA-256: `27f7e13e7b8e9431c05e645b3f9cbb9e3588da0089838da26ac047e61ab0bebe`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-storage-render-workers-2026-09-08
```

The application, ZIP, build log and `measurement.json` are retained in that ignored
output directory. Xcode used approved access to existing caches. This proves unsigned
build/package consistency only; launch, signing, notarization, distribution and
production-server model validation remain open. This subsequent documentation-only
commit does not change candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations,
   compatibility CRUD/thumbnail helpers, conflicts/tombstones and deferred event
   replay still have synchronous MainActor paths. Admission serializes unrelated
   roots. Analysis repository initialization still resolves paths and prepares the
   default Application Support location synchronously. Continue the remaining
   initializer/service and lower-level async closure audit, including legacy
   ImageIO/Metal continuation task-context boundaries. Keyword source/snapshot reads
   still occupy the managed worker; route/preferences publication remains separate
   from file commits. Atomic JSON/template ordering remains per service instance;
   cross-process/device atomicity and shared metadata throughput remain unproven.
2. **Performance and interaction:** agree hardware tiers and budgets; measure local
   SSD, network, iCloud placeholders, read-only and large-folder workloads with
   Instruments, including large RAW/HDR, GPU memory and navigation/export cancellation.
   Run VoiceOver, keyboard/IME, contrast, Reduce Motion, permission and changing-display
   drills, including Known People, Trash recovery, Workspace/Layout, Advanced Export
   and Clean Feed. Per-pixel mid-raster cancellation is not established by this work.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore
   and crash-interruption drills; protected release-branch CI enforcement; focused
   Known People privacy/legal review; real FTP/FTPS/SFTP certificate, host-key and
   transfer-failure exercises.
4. **Model and release:** signed/notarized distribution and production-server model
   install, offline use, update, rollback, removal/relaunch and interrupted/corrupt
   downloads across supported macOS versions. An unsigned candidate does not close
   those gates.
5. **Conditional work:** AI-origin analysis still needs explicit product approval
   plus model/license/corpus decisions. Multilingual strings, pseudolocalization and
   layout coverage remain conditional; template recovery uses Trash without in-app Undo.
