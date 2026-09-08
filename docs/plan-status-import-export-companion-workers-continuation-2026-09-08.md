# Import, export and companion storage workers — 2026-09-08

## Scope

This continuation advances audit Phase 3.1 and delivery Phase 12. Audit remains
**66 of 75** and delivery **119 of 142** complete. The broad storage-ownership
items and manual/device/release gates remain open.

- Twenty-nine filesystem actors now retain Dispatch executors. The migrated paths
  include import source discovery, preflight, capture dates, folder suggestions,
  voice-memo association and copy verification; export directories, artifact
  finalization, Camera RAW resolution, preview storage and decoding, RAW archive
  access/cleanup and analysis export; recent/favorite bookmarks, face signature and
  folder storage, rename identities, voice-memo rename planning and DNG discovery;
  text/bundle/LUT imports, text export, Quick List creation, code-replacement source
  access, cloud download requests and folder-monitor setup.
- Import copy verification stays within its filesystem actor. Cancellation during
  a backup leg now reports the already-committed primary through progress before
  propagating cancellation. Unpromoted staging files are removed. Preflight checks
  cancellation after its final collision probe, and source discovery checks again
  after its final progress callback. Discovery progress is explicitly independent
  of MainActor isolation.
- Advanced Export loupe rendering no longer creates a detached task. Reference
  rendering and encoded-image reads retain the caller's task context on the service
  worker. A final cancellation check rejects the result before cache insertion or
  publication, while the render slot is released for the next request.

Three sub-agents implemented import, export and companion-file slices. The parent
implemented text/cloud/LUT/monitor workers, registered the new test files, reviewed
integration, and maintained validation and plans. Cross-review prompted the loupe
follow-up. The Debug compiler enables `NonisolatedNonsendingByDefault`; plain async
renderer methods cannot be assumed to leave the caller's actor merely from their
`nonisolated` declaration. This continuation does not claim a complete render-path
executor or performance audit.

## Validation

The focused run passed **24 tests in 5 suites**, zero failures, in **0.136 seconds**.
The final-source unfiltered run passed **2,313 tests in 271 suites**, zero failures,
in **92.951 seconds**. Repository validation and whitespace checks passed.

Coverage checks actual Dispatch isolation, task-local and priority retention,
read cancellation, balanced bookmark access, exact processed prefixes, durable
writes, primary/backup copy outcomes and staging cleanup, and cancelled loupe cache
exclusion and render-slot release. Tests use injected filesystem seams and real
local temporary files; they do not establish slow-provider or hardware performance.

The initial sandboxed build could not write existing compiler/package caches;
approved Xcode access resolved that restriction. Integration corrected a queue
assignment accidentally placed inside a DNG default closure and the import progress
value's implicit MainActor isolation. The first runtime run caught macOS temporary
path aliases in an assertion and MainActor inheritance in injected bookmark-test
callbacks. Canonical path comparison and explicit Sendable callbacks corrected those
test harness issues before the successful focused and full runs.

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
```

Logs are retained at `/private/tmp/aagedal-file-workers-focused.log`,
`/private/tmp/aagedal-file-workers-full-tests.log` and
`/private/tmp/aagedal-file-workers-repository.log`. The final `.xcresult` in existing
DerivedData is timestamped `2026.09.08_22-01-00-+0200`.

Implementation commits: `5cbf37a` (export), `dfac334` (import), `e708124`
(companion files), `d8e5519` (progress isolation), `a551018` (loupe), `b608fe8`
(bookmark test callbacks), and `3ce8dbe` (text/cloud/monitor integration and test registration).

No manual interaction, physical-volume performance, production-server or signed-release
validation is claimed.

## Current-source unsigned Release candidate

A clean-source candidate built from `9dfbbe95a08b16d77bf1de0013a48dcf95e3511f`, version
**3.0.0 (738)**, with Xcode 26.6 (17F113) on arm64 macOS
27.0 (26A5425a). Model omission passed and all **79** ZIP payload
entries match the built application. The bundle contains 73 regular files totaling
145,368,274 bytes; the ZIP is 49,758,432 bytes.
ZIP SHA-256: `d1d6eb925e0087314fdb7f8728fd74095d4fae37c7f86394a9a66dde3878b5a7`.

```sh
python3 -B scripts/ci/build_model_free_candidate.py \
  build/model-omission-candidate-import-export-workers-2026-09-08
```

The application, ZIP, build log and `measurement.json` are retained in that ignored
output directory. Xcode used approved access to existing caches. This proves unsigned
build/package consistency only; launch, signing, notarization, distribution and
production-server model validation remain open. This subsequent documentation-only
commit does not change candidate application source.

## Remaining work

1. **Storage ownership:** Known People cold root/database loading, migrations,
   compatibility CRUD, thumbnail helpers, clear/reset, conflicts/tombstones and
   deferred event replay still have synchronous MainActor paths. Mutation admission
   serializes unrelated roots. Remaining file services, rendering entry points and
   lower-level async closures need an executor audit. Keyword source/snapshot reads
   and retention deletion occupy the managed worker; route/preferences publication
   is separate from final file commits. Atomic JSON/template ordering remains per
   service instance, and in-process ordering does not prove cross-process or
   cross-device atomicity. Measure shared metadata worker throughput.
2. **Performance and interaction:** agree hardware tiers and budgets; measure local,
   network, iCloud placeholder, read-only and large-folder workloads with Instruments;
   validate large RAW/HDR and GPU/cancellation stress. Run VoiceOver, keyboard, IME,
   contrast, Reduce Motion, permission and changing-display drills, including Known
   People, Trash recovery, Workspace/Layout, Advanced Export and Clean Feed.
3. **Recovery and external gates:** upgrade/downgrade/newer-schema, backup/restore
   and crash-interruption drills; protected release-branch CI enforcement; focused
   Known People privacy/legal review; real FTP/FTPS/SFTP certificate, host-key and
   transfer-failure exercises.
4. **Model and release:** signed/notarized distribution and production-server model
   install, offline use, update, rollback, removal/relaunch and interrupted/corrupt
   downloads across supported macOS versions. An unsigned local candidate does not
   close those gates.
5. **Conditional work:** AI-origin analysis still needs explicit product approval
   plus model/license/corpus decisions. Multilingual strings, pseudolocalization and
   layout coverage remain conditional; template recovery uses Trash without in-app Undo.
