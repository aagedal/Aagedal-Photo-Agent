# Person deletion, thumbnail preparation, and keyword executor — 2026-09-08

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. Broad storage ownership and
manual/device/release gates remain open.

- Production Known People deletion performs the tombstone/record transaction and
  derived-thumbnail cleanup on the serialized archive worker. Destination reservations
  protect overlapping local writes; unrelated records remain editable. Cancellation
  after admission does not interrupt the durable transition. Failure retains rollback
  semantics, and a failed marker rollback invalidates caches to reflect the surviving
  marker. Delete controls suppress duplicate requests and stale cancellation errors.
- Adding a face group prepares centered embedding JPEGs and representative JPEGs on
  a thumbnail actor. Immutable encoded bytes share the existing bounded display cache's
  lifetime. Preparation normalizes EXIF orientation, tolerates unavailable/corrupt
  thumbnails, and checks cancellation. Folder and face revisions guard storage admission
  and subsequent UI publication.
- Managed keyword filesystem transactions use a retained Dispatch serial executor,
  keeping blocking provider operations off Swift's cooperative thread pool. The original
  task still carries cancellation and task-local routing, and synchronous transactions
  retain their existing ordering. Long transactions still serialize all managed roots.

Three sub-agents implemented these independent slices. The parent reviewed integration,
requested orientation, rollback-failure and duplicate-submission coverage, and ran validation.
The Known People slices share commit `60956c6` because their explicit staging operations
overlapped; the keyword executor is committed separately as `da2e287`. Worker-owned
deletion logging was corrected in `593047e` after the initial build exposed its actor
isolation error.

## Validation

The final-source application/test build and unfiltered suite passed **2,252 tests in
261 suites**, zero failures, in **76.595 seconds** of Swift Testing execution.
Repository validation and `git diff --check` passed.

New coverage includes four thumbnail preparation tests (center crop/dimensions, EXIF
orientation, invalid inputs and cancellation), a pre-cancelled deletion/retry test and
six parameterized deletion outcomes (success, cancellation during I/O, root replacement,
marker failure, record failure with rollback, and rollback failure). Deletion tests check
off-main I/O, reservations, unrelated peer changes, durable bytes, peer invalidation and
reservation release. The keyword executor regression checks actual queue ownership,
task-local routing, exact commit bytes and cancellation evidence after a durable write.
Existing tests cover cross-service serialization and queued cancellation.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs: `/private/tmp/aagedal-deletion-thumbnail-executor-tests.log` and
`/private/tmp/aagedal-deletion-thumbnail-executor-repository.log`. The Xcode result
bundle is in the existing DerivedData test logs with timestamp
`2026.09.08_20-12-28-+0200`. Xcode required approved access to existing compiler/package
caches after the sandboxed attempt failed. A subsequent initial build caught the logging
isolation error described above; the successful unfiltered run includes its correction.
No manual interaction, physical-volume performance or production-server evidence is claimed.

## Current-source unsigned candidate

The clean-source Release build succeeded from `933d9b895a5c276507b32b687a86f560eaf95a24`,
version **3.0.0 (738)**, using Xcode 26.6 (17F113) on arm64 macOS 27.0 (26A5425a).
Model omission passed and all **79** archive payload entries match the built application.
The bundle contains 73 regular files totaling 145,189,778 bytes; the ZIP is 49,712,198 bytes.
ZIP SHA-256: `80a189b062ec33c78bd4f6894516b4155b808ebd6b993ec1a186d19c32265d6b`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-deletion-thumbnail-2026-09-08
```

The application, ZIP, build log and `measurement.json` are retained in that ignored output
directory. Xcode used approved access to its existing caches. This is unsigned build/package
evidence only; no launch, signing, notarization, distribution or production-server validation
is claimed. The subsequent documentation-only commit does not change candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations, low-level
   CRUD and thumbnail helpers, merge/reset, conflict/tombstone maintenance, and deferred
   event replay still contain synchronous MainActor work. Process-wide admission serializes
   unrelated roots. Keyword snapshots, source reads and retention still occupy the shared
   managed executor; route/preferences publication remains separate from final commits.
   Cross-process/cloud-device atomicity is unresolved.
2. **Performance and interaction:** agree hardware tiers and budgets; gather local/network/
   placeholder/read-only/large-folder measurements, Instruments and RAW/HDR evidence,
   GPU/cancellation stress, keyboard/VoiceOver, IME, contrast, Reduce Motion, privacy and
   permission checks. Validate Trash recovery, Workspace/Layout, Advanced Export and
   Clean Feed on actual changing displays.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   crash-interruption drills; protected release-branch CI enforcement; Known People
   privacy/legal review; real FTP/FTPS/SFTP certificate, host-key and failure exercises.
4. **Model and release:** production-server installation, offline use, update, rollback,
   removal/relaunch and interrupted/corrupt downloads on supported macOS versions;
   signing, notarization and distribution. The current-source unsigned candidate above
   supplies local build/package evidence only.
   Conditional AI-origin analysis still requires model/license/corpus decisions and
   explicit product approval.
5. **Conditional follow-ups:** multilingual strings catalog, pseudolocalization and
   layout coverage if planned; template recovery uses Trash without in-app Undo.
