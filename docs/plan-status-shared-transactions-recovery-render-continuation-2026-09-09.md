# Shared storage transactions, recovery and rendering — 2026-09-09

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. The broader storage, manual,
device and release gates remain open.

- Atomic JSON primary/backup transactions now share process-wide admission across
  store instances and document types. Either overlapping primary or backup paths
  prevent concurrent transactions. Canonicalization resolves the nearest existing
  ancestor for absent descendants and pins the actual I/O paths before waiting;
  retargeting a symlink cannot reroute a queued transaction. Directory URL hints do
  not split admission identity. Independent paths remain available, failures release
  ownership, and saves retain their existing durable-after-cancellation behavior.
- Metadata and Develop template CRUD operations share admission for the complete
  storage root, including shortcut reassignment across multiple files. Metadata
  import preview and commit participate in the same ordering. A captured root and
  security access lease survive waiting and subsequent file operations. Cancelled
  requests skip initial access or admitted mutation as appropriate; existing durable
  partial-result evidence remains intact. Repeated IDs in a template import now
  have matching preview and committed added/overwritten counts.
- Keyword recovery reads run on a separate retained Dispatch worker. A slow source
  scan cannot occupy managed-list edit/restore transactions. Missing and empty files
  remain distinguishable from unreadable or invalid UTF-8 files. Cancellation skips
  queued access and discards incomplete scans; request, root and store-version guards
  reject stale MainActor publication.
- Cold Known People embedding removal and ZIP export prepare root resolution and
  legacy migration asynchronously under existing admission. Embedding removal
  rechecks preparation after reacquiring mutation ownership. An export captures its
  records and thumbnail paths together; a completed ZIP remains a success after a
  storage switch and retains its original source snapshot.
- Embedded RAW extraction retains the caller's task on per-request serial executors
  targeting a shared concurrent Dispatch queue. Enforced default thread QoS preserves
  the ImageIO priority safeguard while task locals, priority and cancellation remain
  visible. Queued cancellation skips decoding and cancellation during decoding
  discards completed pixels. Independent decodes remain concurrent.
- Asynchronous offscreen Metal rendering retains caller context on the same serial
  queue as its synchronous facade. Running GPU work completes before reusable state
  is released, while cancelled results are discarded. Camera Raw wrappers skip
  fallback filters and crop processing once cancelled.
- Thumbnail ImageIO decoding and final Core Image materialization retain their task
  on enforced-utility Dispatch executors. After awaiting the Metal edit, the task
  resumes on the thumbnail worker before materializing pixels. The original ImageIO
  options, 480-pixel size cap, baked orientation and SDR output format remain intact.
  Cancelled requests skip subsequent stages and publication; independent thumbnail
  workers remain concurrent under the existing load-admission gate.

Three sub-agents implemented and reviewed the Known People, transaction and rendering
slices. The parent implemented keyword recovery, reviewed integration, ran validation,
committed completed work and maintained the plans. Cross-review corrected directory
URL identity, absent-descendant alias handling, duplicate import counts and durable
export completion reporting before final validation.

## Validation

The final-source unfiltered suite passed **2,383 tests in 277 suites**, zero failures,
in **84.061 seconds**. Repository validation and whitespace checks passed. The final
`.xcresult` in existing DerivedData is timestamped `2026.09.09_21-26-03-+0200`.
Logs: `/private/tmp/aagedal-plan-storage-recovery-final-tests.log` and
`/private/tmp/aagedal-plan-storage-recovery-repository-final.log`.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check 8f09343..HEAD
```

Regression coverage includes real canonical and retargeted-alias storage, overlapping
primary/backup schemas, independent roots, template shortcut/import ordering, directory
URL hints, caller task locals and priority, observed default/utility thread QoS, queued
and running cancellation, durable migration/export outcomes, recovery/restore overlap,
stale recovery publication and actual TIFF orientation/size/SDR rendering. Fixtures
use local temporary storage and injected provider boundaries. They do not establish
physical-volume, real RAW corpus, production-server, manual UI or target-hardware
performance evidence.

The first focused run covered 126 tests in five suites. Its only failure was a new
TIFF fixture that assumed the secondary image would supply the thumbnail: ImageIO
used its primary-image fallback. The corrected fixture tags the primary orientation
and verifies the actual rotated dimensions. That change passed the next unfiltered
run: **2,378 tests in 276 suites**, zero failures, in **83.354 seconds**. The final run
also includes the subsequent directory-key correction and thumbnail work.

The first sandboxed Xcode command could not write existing compiler/package caches.
Approved Xcode access resolved the build restriction. All new tests use existing
test files, so no project registration was needed.

Implementation commits: `76340f3` (keyword recovery), `ad75d04` (Known People),
`ad4788a` (RAW/Metal), `adfcc4e` (shared storage transactions), and `3bb9542`
(thumbnail workers).

## Current-source unsigned Release candidate

A clean-source candidate built from `3bb954226e3b75c2f2e812e93dc02d0e898800ed`, version
**3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS 27.0 (26A5425a).
Model omission passed, and all **79** ZIP payload entries match the built application.
The bundle contains 73 regular files totaling 145,693,810 bytes; the ZIP is 49,832,188
bytes. ZIP SHA-256: `58d4eb6720c077ba415d6d88837fc5238bd994e1e6ce2f27750b039c05f61c66`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-shared-transactions-recovery-render-2026-09-09
```

The application, ZIP, build log and `measurement.json` remain in that ignored output
directory. Xcode used approved access to existing caches. This establishes unsigned
build/package consistency; launch, signing, notarization, distribution and
production-server model validation remain open. The subsequent documentation-only
commit changes no candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold per-person assembly, embedding-version
   migration, synchronous compatibility CRUD/thumbnail helpers, conflicts, tombstones
   and deferred events still have MainActor paths. Known People admission still
   serializes unrelated roots. Keyword snapshot source capture still occupies the
   managed worker, and route/preferences publication remains separate from file
   commits. Backup inventory parsing and structured-keyword tree construction also
   retain MainActor processing. Direct synchronous template compatibility APIs do not
   participate in async admission. Process-wide ordering does not coordinate external
   writers or make multi-file template changes or analysis document/index writes
   crash-atomic. Thumbnail orientation sidecar/header reads and CI materialization,
   plus iCloud availability probes, still run on cooperative executors. QuickLook
   timeout behavior still depends on provider cancellation completing. Continue the
   remaining lower-level ImageIO/Metal audit; blocking provider and GPU calls cannot
   be preempted mid-call.
2. **Performance and interaction:** agree hardware tiers and latency/memory budgets;
   measure SSD, network, iCloud placeholders, read-only and large-folder workloads
   with Instruments, including large RAW/HDR, comparison, GPU memory, startup and
   cancellation. Run VoiceOver, keyboard/IME, contrast, Reduce Motion, permission,
   fixture alignment/color and changing-display/Clean Feed drills.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   process-crash exercises; protected release-branch CI enforcement; focused Known
   People privacy/legal review; real FTP/FTPS/SFTP certificate, host-key and failure
   drills.
4. **Model and release:** signed/notarized distribution and production-server model
   install, offline, update, rollback, removal/relaunch and interrupted/corrupt
   downloads across supported macOS versions. Unsigned candidate checks establish
   build/package consistency only.
5. **Conditional work:** AI-origin analysis needs explicit product approval and
   model/license/corpus decisions. Multilingual strings, pseudolocalization and layout
   coverage remain conditional; template recovery uses Trash without in-app Undo.
