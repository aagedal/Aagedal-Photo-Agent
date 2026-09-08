# Person editing and storage workers — 2026-09-08

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. The broader storage migration
and manual/device/release gates remain open.

- Known People metadata and representative-sample edits await worker persistence. Form edits
  apply only name, role and notes to the current record after mutation admission, preserving
  samples and representative selections changed since the editor opened. Reserved destinations,
  durable peer-cache invalidation, cancellation and storage-revision checks follow the existing
  import/write transaction boundary. Save failures retain editable fields and expose a retryable
  error. Repeated submissions are suppressed while a save is pending. Identity-based bindings
  survive reordered or removed rows, and per-save tokens reject UI completion after changing people
  or leaving the editor without cancelling an admitted durable write.
- The Known People archive actor retains a dedicated Dispatch executor. Coordinated writes,
  archive preparation and cleanup retain the original Swift task's cancellation and task-local
  context while keeping blocking provider operations off the cooperative thread pool.
- `FileSystemService` also retains a dedicated Dispatch executor. Existing scan, classification,
  sidecar/orientation read and mutation boundaries retain their serialized ordering and immutable
  cancellation or durable-commit evidence.
- Keyword archive preview, extraction and packaging each retain separate Dispatch executors.
  Compression and process waits remain independent of managed-list transactions. Failed or
  cancelled preparation removes private staging; cancelled compression preserves the destination.
- Backup preview and history enumeration use separate Dispatch executors, preserving caller
  task context. Snapshot and restore transactions remain uninterrupted on the managed keyword
  executor; this change does not weaken their read/deduplication/safety-copy/write ordering.

Three sub-agents implemented Known People edits, backup workers, and general filesystem workers.
The parent implemented archive workers and ran integration validation. Cross-review examined
executor ownership and identified the async editor binding and test-admission follow-ups.

## Validation

The initial focused run passed **14 tests in 3 suites**, zero failures, in **0.396 seconds**.
It covered archive previews, archive staging and backup previews. The initial sandboxed Xcode
project inspection could not access compiler/package caches; the approved test run used existing
caches successfully. Its log is `/private/tmp/aagedal-storage-workers-focused.log`.

The first unfiltered run passed **2,273 tests in 262 suites**, zero failures, in **76.955 seconds**.
The per-save presentation-token follow-up was committed while that build ran. The final-source
unfiltered run also passed **2,273 tests in 262 suites**, zero failures, in **78.812 seconds**.
The runs are retained in `/private/tmp/aagedal-person-edit-storage-workers-tests.log` and
`/private/tmp/aagedal-person-edit-storage-workers-final-tests.log`. The final `.xcresult` in the
existing DerivedData test logs is timestamped `2026.09.08_21-11-31-+0200`. Repository validation
is retained in `/private/tmp/aagedal-person-edit-storage-workers-repository.log`.

Regression coverage includes 28 new cases across 11 logical tests, including parameterized cases:

- Person edit success, suspended-write failure/cancellation/storage replacement, queued selection
  preservation, missing-record/sample rejection and safe identity bindings after reorder/removal.
- General filesystem executor ownership, task-local propagation, cancellation before and during
  reads, and real temporary-file mutation preserving committed evidence while stopping the next item.
- Archive preview/extraction/compression executor ownership and caller task context, cancellation,
  private staging cleanup and destination preservation.
- Backup preview/history executor ownership, task-local/priority context and cancellation after
  reads, directory enumeration and history inspection.

Repository validation and whitespace checks passed. No manual interaction, physical-volume
performance, production-server or distribution evidence is claimed.

Implementation commits: `bc25052` (backup workers), `33af320` (filesystem worker), `50f82c7`
(archive workers), `d653689` (Known People edits) and `d8279fe` (stale editor completion).

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

## Current-source unsigned candidate

A clean-source Release candidate built from `08d486d2708f6ab1422574b064cd0159f4e54ea9`,
version **3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS 27.0 (26A5425a).
Model omission passed and all **79** ZIP payload entries match the built application.
The bundle has 73 regular files totaling 145,272,754 bytes; the ZIP is 49,733,280 bytes.
ZIP SHA-256: `5f240af9cee11a66c6534ef3c196d4686f6a17055f115cffac98951100bc7cfc`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-person-edit-workers-2026-09-08
```

The application, ZIP, build log and `measurement.json` are retained in that ignored output
directory. Xcode used approved access to existing caches. This is unsigned build/package
evidence only; no launch, signing, notarization, distribution or production-server validation
is claimed. The subsequent documentation-only commit does not change candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations, compatibility CRUD,
   thumbnail helpers, clearing/reset, conflicts/tombstone maintenance and deferred event replay still
   contain synchronous MainActor work. Process-wide mutation admission serializes unrelated roots.
   Other file services still use cooperative actor executors. Keyword source/snapshot reads and
   retention deletion occupy the shared managed executor; route/preferences publication remains
   separate from final commits. In-process ordering does not provide cross-process/cloud-device
   atomicity, and backup retention assumes immutable, uniquely named app-managed local history.
2. **Performance and interaction:** agree hardware tiers and budgets; gather local/network/
   placeholder/read-only/large-folder measurements, Instruments and RAW/HDR evidence, GPU/cancellation
   stress, keyboard/VoiceOver, IME, contrast, Reduce Motion, privacy and permission checks. Validate
   async Known People editors, Trash recovery, Workspace/Layout, Advanced Export and Clean Feed on
   actual changing displays.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   crash-interruption drills; protected release-branch CI enforcement; Known People privacy/legal
   review; real FTP/FTPS/SFTP certificate, host-key and failure exercises.
4. **Model and release:** production-server install, offline use, update, rollback, removal/relaunch
   and interrupted/corrupt downloads on supported macOS versions; signing, notarization and distribution.
   Conditional AI-origin analysis requires model/license/corpus decisions and explicit product approval.
5. **Conditional follow-ups:** multilingual strings catalog, pseudolocalization and layout coverage
   if planned; template recovery uses Trash without in-app Undo.
