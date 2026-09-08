# Person merging, backup retention, and cloud workers — 2026-09-08

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. Broad storage ownership and
manual/device/release gates remain open.

- Production Known People merging moves target encoding/writing, source tombstone/deletion,
  and derived-thumbnail cleanup onto the serialized archive worker. Reservations cover both
  records and their thumbnails while unrelated people remain editable. Durable target writes,
  source deletion, and failed marker rollback invalidate peer caches even if later work fails.
  Retry preserves thumbnails already referenced by a target from an earlier partial merge.
  The UI awaits the operation and suppresses repeated submissions. A batch shares one storage
  revision so switching roots stops remaining merges and stale failure presentation.
- Backup retention scans immutable local history on a dedicated Dispatch actor. Only deletion
  of the resulting expired-file plan returns to the managed keyword executor; overlapping
  retention passes serialize across scan and commit. Concurrent snapshots can add history
  without entering the deletion plan. Unavailable history and the minimum useful readable
  versions stay protected. Snapshot read/deduplication/write and restore safety-copy/write
  transactions remain synchronous on the managed executor.
- iCloud availability, Templates, Teams/Watermarks, Known People routing, and keyword root
  resolution retain dedicated Dispatch executors. Blocking provisioning and coordinated
  copies keep the caller's task context and cancellation without occupying Swift's cooperative
  pool. Keyword root lookup now rejects cancellation that arrives during provisioning.

Two sub-agents implemented merge and retention changes. The parent implemented cloud workers,
reviewed integration, and ran validation; a third sub-agent performed read-only review.

## Validation

The focused cloud/root run passed **39 tests in 2 suites**, zero failures, in **1.328 seconds**.
The initial sandboxed Xcode invocation could not access compiler/package caches; the approved
run used existing caches successfully. Its log is
`/private/tmp/aagedal-cloud-workers-focused.log`.

New regression coverage checks:

- Nine merge success/failure/suspension outcomes, cancellation before admission, and batch
  root replacement with identical person IDs in both stores. Failure cases include target write,
  marker write, record deletion, failed marker rollback, and best-effort thumbnail cleanup.
- Explicit and snapshot-triggered retention scans allowing managed restore to proceed, queued
  cancellation, cancellation during inspection, durable snapshot cancellation, and two admitted
  passes observing four then two versions while preserving the minimum two. Injected I/O verifies
  actual Dispatch scan and managed deletion executor ownership.
- Cloud/root executor ownership, task-local propagation, security-scope release on the same
  executor, cancellation during provisioning, and durable cancellation during coordinated merge.

The first unfiltered run executed 2,262 tests with one failure in the new marker-rollback
regression: the test asked a peer database to reload before checking the worker's durable bytes.
That existing lazy-load tombstone maintenance legitimately removed the suppressed record. The
assertions now check disk evidence before requesting a reload; no production change was needed.
The corrected final-source unfiltered run passed **2,262 tests in 261 suites**, zero failures,
in **77.549 seconds** of Swift Testing execution. Repository validation and `git diff --check`
passed. No manual interaction, physical-volume performance or production-server evidence is claimed.

Implementation commits: `556dc33` (Known People merging) and `7ec27a6` (backup retention and
cloud workers).

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Final logs: `/private/tmp/aagedal-merge-retention-routing-final-tests.log` and
`/private/tmp/aagedal-merge-retention-routing-repository.log`. The `.xcresult` is under the
existing DerivedData test logs with timestamp `2026.09.08_20-47-16-+0200`. The earlier failing
run is retained in `/private/tmp/aagedal-merge-retention-routing-tests.log`.

## Current-source unsigned candidate

A clean-source Release candidate built from `b32b4f31e5f6ace384b86fca3d8b6cbef9b671b1`,
version **3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS 27.0 (26A5425a).
Model omission passed and all **79** ZIP payload entries match the built application.
The bundle has 73 regular files totaling 145,217,218 bytes; the ZIP is 49,723,822 bytes.
ZIP SHA-256: `00730bab74130fc545597bdb90fb3cde37e3159a55819d210d7e4dbea9629539`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-merge-retention-2026-09-08
```

The application, ZIP, build log and `measurement.json` are retained in that ignored output
directory. Xcode used approved access to existing caches. This is unsigned build/package
evidence only; no launch, signing, notarization, distribution or production-server validation
is claimed. The subsequent documentation-only commit does not change candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations, low-level CRUD,
   thumbnail helpers, clearing/reset, conflicts/tombstone maintenance, and deferred event replay
   still contain synchronous MainActor work. Process-wide mutation admission serializes unrelated
   roots. Keyword source/snapshot reads and retention deletion still occupy the shared managed
   executor; route/preferences publication remains separate from final commits. Retention assumes
   app-managed immutable, uniquely named local history; external edits and cross-process/cloud-device
   atomicity remain outside the in-process ordering guarantee.
2. **Performance and interaction:** agree hardware tiers and budgets; gather local/network/
   placeholder/read-only/large-folder measurements, Instruments and RAW/HDR evidence, GPU/cancellation
   stress, keyboard/VoiceOver, IME, contrast, Reduce Motion, privacy and permission checks. Validate
   Trash recovery, Workspace/Layout, Advanced Export and Clean Feed on actual changing displays.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   crash-interruption drills; protected release-branch CI enforcement; Known People privacy/legal
   review; real FTP/FTPS/SFTP certificate, host-key and failure exercises.
4. **Model and release:** production-server install, offline use, update, rollback, removal/relaunch
   and interrupted/corrupt downloads on supported macOS versions; signing, notarization and distribution.
   Conditional AI-origin analysis requires model/license/corpus decisions and explicit product approval.
5. **Conditional follow-ups:** multilingual strings catalog, pseudolocalization and layout coverage
   if planned; template recovery uses Trash without in-app Undo.
