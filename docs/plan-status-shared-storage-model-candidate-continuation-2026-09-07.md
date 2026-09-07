# Shared storage and model-candidate continuation — 2026-09-07

## Scope

This continuation advances audit Phases 3.1 and 4.3 and delivery Phase 12. The audit
remains **66 of 75** complete and delivery remains **119 of 142**; the broad storage,
hardware, device, and distribution gates are not complete.

- Editor, Quick List, Approved List import, archive inventory/import/export, backup, legacy migration, and
  keyword routing filesystem transactions now share `KeywordListsFilesystemActor`.
  A synchronous read/merge/write batch cannot interleave with another participating
  service's mutation. Existing captured paths, cancellation, and durable results remain intact.
  Regression coverage holds an editor append open while routing and backup restore queue;
  restore's preimage must contain the fully committed append. Approved List import must also
  wait before entering source access and then commit its own destination.
- Known People import admission and destination reservations span service instances,
  including independently injected archive workers. Conflicting writes and clearing are
  rejected, migrations defer while the root is reserved, and queued imports recheck
  cancellation and storage revision. Deferred deletion and remote events replay after
  publication and invalidate both the origin and import owner's affected caches.
  Tests cover same/cross-instance writes, success/cancellation/rerouting, and remote deletion.
- Release packaging now recursively validates the app for compiled/source AuraFace payloads,
  rejects broken or escaping bundle links, and records version/build and regular-file bytes.
  Six focused tests cover nested/case-varied model payloads, app integrity, and framework links.

Two sub-agents implemented keyword serialization and Known People ownership. The parent
reviewed integration, requested the import-owner cache correction, hardened release validation,
and performed build/test and candidate-size validation.

## Validation

The first full run built the application before the import-owner cache correction landed,
then compiled the expanded regression cases. It ran **2,208 tests in 257 suites** and exposed
four cross-instance remote-deletion assertions. Rebuilding the corrected application and rerunning
the unfiltered suite passed **2,208 tests in 257 suites**, zero failures, in **72.040 seconds**
of Swift Testing execution. Final review found and migrated the separate Approved List import
actor; the final unfiltered rebuild passed **2,208 tests in 257 suites**, zero failures, in
**68.867 seconds**. Both successful runs built the application and test bundle.

`scripts/ci/validate_repository.sh`, the six new model-omission tests, shell syntax checks,
and `git diff --check` passed. Repository validation initially identified an old exact-path
release-guard assertion; it now verifies the recursive validator's release integration.
The validator also correctly rejected the locally preserved 2.2.0 exported app containing AuraFace.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
bash -n scripts/release.sh scripts/ci/validate_repository.sh
git diff --check
```

Test logs: `/private/tmp/aagedal-shared-storage-tests.log` (initial application revision),
`/private/tmp/aagedal-shared-storage-final-tests.log` (corrected full suite), and
`/private/tmp/aagedal-shared-storage-repository.log`. Final follow-up logs are
`/private/tmp/aagedal-shared-storage-complete-tests.log` and
`/private/tmp/aagedal-shared-storage-complete-repository.log`. Xcode uses existing compiler/package caches.
These automated tests do not substitute for manual, real-volume, or production-server evidence.

## Local model-free candidate

Both local Release builds succeeded. The final candidate was refreshed from committed source
`87fe4c57a17c75ed53633a7d718af23bb8e08792` after the last successful full test run.
The implementation commits are `33ce0c0` and `87fe4c5`.
The local host is macOS 27.0 (26A5425a), arm64, with Xcode 26.6 (17F113).

```sh
xcodebuild build -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent' -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
python3 -B scripts/ci/validate_model_omission.py \
  'build/model-omission-candidate-2026-09-07/Aagedal Photo Agent.app'
```

The 3.0.0 (738) app passes the recursive omission check. It is an **unsigned local Release
build**, with no install, launch, notarization, Sparkle, or production-server drill claimed.
The initial sandboxed build could not write compiler/package caches; the successful builds used
approved access to Xcode's existing caches. Logs are `/private/tmp/aagedal-model-omitted-release.log`
and `/private/tmp/aagedal-model-omitted-release-final.log`.

| Measurement | Bytes |
| --- | ---: |
| Candidate regular files (73 files) | 144,908,482 |
| Candidate ZIP | 49,640,262 |
| Same candidate ZIP with only the preserved legacy compiled model added | 170,033,832 |
| ZIP reduction attributable to omitting that model | 120,393,570 |
| Excluded compiled model's regular files | 130,655,454 |

The paired archives use `/usr/bin/ditto -c -k --keepParent`. The comparison adds only
`build/release/export/Aagedal Photo Agent.app/Contents/Resources/AuraFaceR100.mlmodelc`
from the preserved 2.2.0 release to a temporary copy of the current app. This isolates the
model's packaging contribution; it is **not** a comparison of complete historical releases
or a signed/notarized update-size measurement. The temporary comparison app is removed.

Candidate ZIP SHA-256:
`e91a5574e5377e4eea5468ebdcda574f418bf43e8174363016514b0479c3cfe6`.
The app, both comparison ZIPs, and machine-readable `measurement.json` are retained under
`build/model-omission-candidate-2026-09-07/` (ignored build artifacts). The one-off measurement
command is `/private/tmp/aagedal-measure-model-candidate.py`; it requires clean application/project
sources, refuses to overwrite an existing candidate, verifies omission, and records the source revision.

This supplies local candidate and package-size evidence. A signed distribution candidate and the
supported-macOS production-server install/offline/update/rollback/removal/relaunch/failure matrix
remain open.

## Remaining work

1. **Known People async ownership:** database loading, root resolution, conflict/tombstone
   maintenance, migrations, normal CRUD, clearing, and deferred replay still contain synchronous
   MainActor filesystem work. Full cross-instance cache coherence needs a shared async database
   owner. The new process-wide FIFO conservatively serializes imports across unrelated roots.
2. **Keyword compatibility and route publication:** synchronous store/archive convenience APIs
   still bypass the shared actor. Routing reconciliation and MainActor preference/cache publication
   remain separate steps, and already-captured requests can commit to an older root. Full archive
   staging occupies the shared actor and can delay other keyword operations. Cross-process and
   cloud-device atomicity is not provided by an in-process actor.
3. **Performance and interaction:** agreed hardware/budgets; local/network/iCloud-placeholder/
   read-only/large-folder responsiveness; Thread Performance Checker and RAW/HDR Instruments
   evidence; long-running GPU/cancellation; multi-display, accessibility, IME, localization,
   contrast, Reduce Motion, source permissions, and runtime privacy checks.
4. **Recovery and external gates:** real upgrade/downgrade, backup/restore, and crash-interruption
   drills; protected release-branch CI enforcement; Known People privacy/legal review;
   real FTP/FTPS/SFTP certificate/host-key and failure drills.
5. **Model and release gates:** production-server clean install, offline, update, rollback,
   removal, relaunch, and interrupted/corrupt download checks on supported macOS tiers;
   signed/notarized release packaging and distribution. The conditional AI-origin analyzer
   still requires model/license/corpus decisions and explicit product approval.
