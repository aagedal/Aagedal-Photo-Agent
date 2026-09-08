# Metadata and library storage executors — 2026-09-08

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. Broader storage ownership and
manual/device/release gates remain open.

- Teams and Watermark persistence retain dedicated Dispatch executors for directory
  enumeration, conflict resolution, thumbnails, record writes and durable deletion.
  PNG import still finishes its admitted image/metadata pair after cancellation.
- Template CRUD, import preview and import commit retain dedicated Dispatch executors.
  Read cancellation and durable partial writes remain explicit; Trash recovery and
  shortcut-slot reconciliation retain their existing behavior.
- Known People thumbnail reads/replacement preparation and storage-size enumeration
  retain dedicated Dispatch executors. Cancelled reads do not publish images or partial
  byte counts; unavailable storage remains distinguishable from empty storage.
- Atomic JSON stores retain dedicated Dispatch executors for reads, schema checks,
  synchronized staging, backup installation and atomic replacement. Admitted saves
  still finish after cancellation, retaining the previous valid primary as backup.
- Metadata editor reads use a dedicated executor. Serialized JSON/XMP operations route
  their actual storage transactions onto a shared Dispatch worker, including revision
  retries and lock-key resolution. Per-photo coordination and folder barriers retain
  ownership across suspension; admitted writes still return durable evidence.
- Browser XMP/HDR inspection, FTP sidecar inspection and both Raw Metadata sidecar readers
  retain separate Dispatch executors with the existing exact cancellation-prefix results.

Three sub-agents implemented the template, library and metadata slices. The parent
implemented Known People/atomic JSON workers, coordinated cross-review and validation,
and maintained the plans. Independent reviews found no correctness issue in retained
executor ownership or cancellation semantics. These changes do not prove performance on
slow providers: a shared metadata worker can delay unrelated photos behind blocking I/O.

## Validation

The initial focused run passed **34 tests in 6 suites**, zero failures, in **0.343 seconds**.
It covered atomic JSON storage, Known People reads, template executors, metadata executors,
and Teams/Watermark persistence. The first sandboxed build could not access existing
compiler/package caches; approved Xcode access resolved that environment restriction.
An initial test build found a throwing assertion in an inferred nonthrowing closure;
the decode was made explicit before the assertion in both library deletion tests. The
adjacent XMP test also needed an explicit nil comparison for its optional cleared title.

New and strengthened regression coverage checks executor ownership, task-local and priority
propagation, cancellation before and during reads, durable writes despite cancellation, thumbnail
preparation, backup preservation, template partial commits, metadata revision retries, bounded bulk
reads, JSON history/cleanup/deletion, and XMP descriptive/Develop separation.

The final-source unfiltered run passed **2,289 tests in 266 suites**, zero failures,
in **82.270 seconds**. Log: `/private/tmp/aagedal-storage-executors-full-tests.log`.
The `.xcresult` in existing DerivedData is timestamped `2026.09.08_21-32-49-+0200`.
Repository validation and whitespace checks passed after integration.

Implementation commits: `9c2cf58` (templates), `4f51290` (Teams/Watermarks), `46232dc`
(deletion test compilation), `e3e0d25` (metadata reads/transactions), `be31110` (atomic JSON
and Known People reads), `21e1714` (Browser/FTP/Raw Metadata), and `588788f` (remaining
async JSON/XMP operations).

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Focused log: `/private/tmp/aagedal-storage-executors-focused.log`.
Repository checks passed in `/private/tmp/aagedal-storage-executors-repository.log`.
No manual interaction, physical-volume performance, production-server or signed-release
validation is claimed.

## Current-source unsigned candidate

A clean-source Release candidate built from `33b96ff60f1727fdc532fdd3780d4f8be04d5f20`,
version **3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS
27.0 (26A5425a). Model omission passed and all **79** ZIP payload
entries match the built application. The bundle contains 73 regular files totaling
145,342,482 bytes; the ZIP is 49,752,213 bytes.
ZIP SHA-256: `9cbb38923550b547258f6a788191b47ecb214940d975ba679bf26fd9bab604de`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-metadata-library-executors-2026-09-08
```

The application, ZIP, build log and `measurement.json` are retained in that ignored output
directory. Xcode used approved access to existing caches. This is unsigned build/package
evidence only; no launch, signing, notarization, distribution or production-server validation
is claimed. The subsequent documentation-only commit does not change candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations, compatibility
   CRUD, thumbnail helpers, clearing/reset, conflicts/tombstone maintenance and deferred
   event replay still contain synchronous MainActor work. Mutation admission still serializes
   unrelated roots. Other file services still use cooperative actor executors. Keyword
   source/snapshot reads and retention deletion occupy the shared managed executor;
   route/preferences publication remains separate from final commits. Atomic JSON and
   template ordering are per service instance, and in-process ordering does not establish
   cross-process/cloud-device atomicity. Shared metadata worker throughput needs measurement.
2. **Performance and interaction:** agree hardware tiers and budgets; gather local/network/
   placeholder/read-only/large-folder measurements, Instruments and RAW/HDR evidence,
   GPU/cancellation stress, keyboard/VoiceOver, IME, contrast, Reduce Motion and permission
   checks. Validate Known People editing, Trash recovery, Workspace/Layout, Advanced Export
   and Clean Feed on actual changing displays.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   crash-interruption drills; protected release-branch CI enforcement; Known People privacy/legal
   review; real FTP/FTPS/SFTP certificate, host-key and failure exercises.
4. **Model and release:** production-server install, offline use, update, rollback,
   removal/relaunch and interrupted/corrupt downloads on supported macOS versions; signing,
   notarization and distribution. Conditional AI-origin analysis needs model/license/corpus
   decisions and explicit product approval.
5. **Conditional follow-ups:** multilingual strings catalog, pseudolocalization and layout
   coverage if planned; template recovery uses Trash without in-app Undo.
