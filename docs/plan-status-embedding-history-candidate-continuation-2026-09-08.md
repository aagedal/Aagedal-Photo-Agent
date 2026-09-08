# Embedding removal, backup history, and current-source candidate — 2026-09-08

## Scope

This continuation advances audit Phase 3.1, delivery Phase 12, and local model-free
candidate validation. The audit remains **66 of 75** and delivery **119 of 142**:
these bounded improvements do not close the broad storage or manual/device/release gates.

- Known People embedding removal writes its person record, removes the embedding image,
  and writes any prepared representative image on the serialized archive worker. It reserves
  affected destinations across service instances and reloads the current person after admission
  to preserve edits made during suspension. Durable results invalidate peer caches even after
  cancellation or a storage switch. Thumbnail cleanup remains best effort, with private failure
  diagnostics; a failed record write preserves the old images. A committed removal invalidates
  cached and suspended thumbnail reads even when the image file was already absent.
- Keyword backup-history inventory has a separate serialized actor. Slow history enumeration
  and file reads no longer occupy the managed keyword transaction actor. History remains advisory:
  concurrent pruning can make an enumerated version unavailable. Snapshot creation, retention,
  restores, and exact preimage preservation retain the shared managed actor.
- `scripts/ci/build_model_free_candidate.py` replaces the temporary candidate command with a
  reproducible repository entry point. It requires clean committed source, rejects existing
  output directories, rechecks source identity after building and packaging, recursively validates
  model omission, and records the build command, host/toolchain, version/build, package bytes,
  and SHA-256. A success manifest is written only after all checks pass. It never signs,
  notarizes, publishes, launches, or performs production-server tests.

Two sub-agents implemented the storage slices. The parent reviewed integration, requested
explicit thumbnail failure evidence and a missing-file cache correction, implemented candidate
packaging, and ran application/test, repository, and Release validation.

Implementation commits: `9a30b43` (candidate command), `4349ba2` (backup history), and
`2bac0ad` (embedding removal).

## Validation

The integrated application/test build and unfiltered suite passed **2,238 tests in 260 suites**,
zero failures, in **78.074 seconds** of Swift Testing execution. Final review then found and fixed
missing-file thumbnail cache invalidation. The final-source rebuild and focused storage run passed
**63 tests in 2 suites**, zero failures, in **8.936 seconds**. That includes both warm-cache and
suspended-peer-read missing-file regressions.

New embedding removal coverage exercises success, cancellation during I/O, changed storage,
failed record writes, failed image cleanup/replacement, deferred peer deletion, cached images,
and suspended reads. The backup regression holds inventory enumeration open while a managed
restore commits. Five Python candidate tests cover dirty/staged/untracked source, changed commits,
existing output preservation, output containment, and ignored generated output. Repository
validation and `git diff --check` passed.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:'Aagedal Photo Agent Tests/KnownPeopleServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/KeywordListBackupFileServiceTests'
scripts/ci/validate_repository.sh
python3 -B scripts/ci/build_model_free_candidate.py build/model-omission-candidate-2026-09-08
```

Xcode validation used approved access to existing package/compiler caches. Logs:
`/private/tmp/aagedal-embedding-history-tests.log`,
`/private/tmp/aagedal-embedding-history-final-tests.log`,
`/private/tmp/aagedal-embedding-history-repository-complete.log`, and
`build/model-omission-candidate-2026-09-08/build.log`.

## Local candidate

The unsigned Release build succeeded from clean committed application source
`2bac0adf3d523ad6146dd9de4782055c8678af85` on macOS 27.0 (26A5425a), arm64,
with Xcode 26.6 (17F113). Version 3.0.0 (738) passes recursive model omission.

| Measurement | Result |
| --- | ---: |
| Regular files | 73 |
| Regular-file bytes | 145,110,498 |
| ZIP bytes | 49,684,926 |

ZIP SHA-256: `6e1973640874b2b61620299a53012222853996c6d4bddb8aa62ad4ce4a8a25f6`.

The app, ZIP, build log, and `measurement.json` are retained under the ignored
`build/model-omission-candidate-2026-09-08/` directory. This refreshes the earlier candidate
with the current application changes. No new paired legacy-model size comparison, install,
launch, production-server drill, signing, notarization, or distribution is claimed.

## Remaining work

1. **Storage ownership:** Known People root/database loading, ordinary CRUD, migrations,
   conflicts/tombstones, clearing, other thumbnail writes, and deferred event replay still
   contain synchronous MainActor work. The process-wide FIFO also serializes unrelated roots.
   Keyword route/preference publication remains separate from final actor commits, so already
   captured requests can write to an older root. Archive snapshot copying occupies the managed
   actor. Cross-process/cloud-device atomicity still requires broader ownership work.
2. **Manual performance and interaction:** agree hardware tiers and budgets; measure local,
   network, iCloud-placeholder, read-only, and large-folder behavior; collect Instruments/RAW/HDR,
   GPU/cancellation, accessibility/keyboard/VoiceOver, IME, contrast, Reduce Motion, privacy and
   permissions evidence. Validate template Trash recovery, Workspace/Layout navigation, and
   Advanced Export/Clean Feed on actual changing displays.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore, and crash
   interruption drills; protected release-branch CI enforcement; Known People privacy/legal
   review; real FTP/FTPS/SFTP certificate, host-key, and failure exercises.
4. **Model and release:** production-server install/offline/update/rollback/removal/relaunch and
   interrupted/corrupt-download drills on every supported macOS tier; signed/notarized distribution
   and release steps. The refreshed local unsigned candidate closes none of those external gates.
   Conditional AI-origin analysis still needs model/license/corpus decisions and product approval.
5. **Conditional follow-ups:** strings catalog, pseudolocalization, and layout coverage if
   multilingual distribution is planned. Template recovery remains through Trash, with no in-app Undo.
