# Known People additions, backup snapshots, and package verification — 2026-09-08

## Scope

This continuation advances audit Phase 3.1, delivery Phase 12, and local candidate
validation. Audit remains **66 of 75** and delivery **119 of 142**: broad storage
ownership and manual/device/release gates remain open.

- The production Known People add/merge path writes thumbnails and encodes/writes person
  records on the serialized archive worker. Destination reservations protect overlapping
  local mutations; durable partial results invalidate peer caches after failures,
  cancellation, or storage changes. Merges reload the latest person after admission;
  queued additions recheck names to prevent duplicate records. The UI awaits completion
  and prevents repeated submissions. Existing creation and merge write ordering is retained;
  this does not introduce atomic multi-file commits or rollback.
  Roster linking checks folder, face and match revisions after suspension and suppresses
  stale success/error publication; completed durable writes remain intact.
- Unchanged keyword snapshots read only the newest historical body. Changed snapshots
  retain one full retention scan, avoiding the earlier duplicate history reads. Timestamp
  names advance monotonically within a service and include UUIDs, preserving distinct
  same-millisecond versions and preventing collisions across service instances. Legacy
  timestamp names remain readable. Cross-device chronological ordering is not established.
- Candidate packaging compares ZIP payload bytes, symlink targets, and executable bits
  against the built app, rejects missing/extra/duplicate/unsafe entries, and reads through
  the archive to verify CRCs. Associated AppleDouble metadata is permitted. Invalid
  packaging cannot publish a success manifest. Recursive model omission and clean-source
  checks still apply.

Two sub-agents implemented the independent storage changes. The parent reviewed integration,
requested queued-add protection and backup collision coverage, implemented package verification,
and ran integrated validation.

Implementation commits: `3bfdeee` (backup reads), `6e55f58` (snapshot filenames),
`1f34fd0` and `27ed9fc` (package verification), `f584b96` (Known People additions),
and `6aa6e69` (roster publication guards).

## Validation

The application/test build and unfiltered suite passed **2,245 tests in 260 suites**,
zero failures, in **80.997 seconds** of Swift Testing execution. The final-source rebuild
and focused storage/roster run passed **73 tests in 3 suites**, zero failures, in
**12.227 seconds**, validating compilation after the subsequent roster publication guard.

Known People regression coverage includes ten parameterized create/merge outcomes plus
queued duplicate admission. Backup coverage checks a 100-version unchanged history,
unreadable newest backups, 1,000 same-millisecond filenames, a backwards clock, distinct
file preservation and latest-content deduplication with legacy history. The Python
candidate suite passes **11 tests**, including real ditto packaging and rejection of
missing/changed/unsafe entries without a success manifest. The existing September 8
candidate ZIP also passes the new byte/link/executable verification (79 payload entries).

Repository validation passed. An initial run overlapped unfinished agent edits and failed
on trailing whitespace; the completed-source rerun passed. Xcode used approved access to
existing compiler/package caches. The roster guard has compilation and source-review
coverage; a runtime suspension test would require new injection seams for its shared
services, and no manual interaction evidence is claimed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:'Aagedal Photo Agent Tests/KnownPeopleServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/KeywordListBackupFileServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/RosterStoreTests'
scripts/ci/validate_repository.sh
python3 -B scripts/ci/test_model_free_candidate.py
git diff --check
```

Logs: `/private/tmp/aagedal-addition-backup-tests.log`,
`/private/tmp/aagedal-addition-backup-final-tests.log`, and
`/private/tmp/aagedal-addition-backup-repository.log`.

## Current-source unsigned candidate

The reproducible Release command succeeded from clean committed source
`f7bd129d87fe3ca81d6df11691734742d3b8726c`, version **3.0.0 (738)**, on macOS
27.0 (26A5425a), arm64, with Xcode 26.6 (17F113). Recursive model omission and
archive payload verification both passed; all **79** regular-file/symlink payload
entries match the built application.

| Measurement | Result |
| --- | ---: |
| Regular files | 73 |
| Regular-file bytes | 145,141,074 |
| ZIP bytes | 49,699,786 |

ZIP SHA-256: `b420f39f41a00bbe2efc442c9f7869abc93c65f0497f46cf427afdfda758ea41`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-addition-backup-2026-09-08
```

The app, ZIP, build log and `measurement.json` are retained under that ignored output
directory. The command uses approved Xcode cache access. This is local unsigned
build/package evidence; no launch, production-server, signing, notarization or distribution
validation is claimed. The following documentation-only commit does not alter candidate
application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations, low-level
   CRUD and thumbnail helpers, deletion/reset, conflicts/tombstones, and deferred event
   replay still contain synchronous MainActor work. Add-group thumbnail preparation also
   remains on MainActor. The process-wide FIFO serializes unrelated roots. Keyword source
   reads, snapshot writes and retention remain on the managed actor; route/preferences
   publication remains separate from final commits. Broader cross-process/cloud-device
   ownership is unresolved.
2. **Manual performance and interaction:** hardware tiers and budgets; local/network/
   placeholder/read-only/large-folder measurements; Instruments, RAW/HDR, GPU/cancellation,
   keyboard/VoiceOver, IME, contrast, Reduce Motion, privacy and permissions. Validate
   template Trash recovery, Workspace/Layout navigation, Advanced Export and Clean Feed
   on actual changing displays.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore and
   crash-interruption drills; protected release-branch CI enforcement; Known People
   privacy/legal review; real FTP/FTPS/SFTP certificate, host-key and failure exercises.
4. **Model and release:** supported-macOS production-server install, offline, update,
   rollback, removal/relaunch and interrupted/corrupt download drills; signing, notarization,
   and distribution. Conditional AI-origin analysis requires model/license/corpus decisions
   and product approval.
5. **Conditional follow-ups:** multilingual strings catalog, pseudolocalization and layout
   coverage if planned; template recovery currently uses Trash without in-app Undo.
