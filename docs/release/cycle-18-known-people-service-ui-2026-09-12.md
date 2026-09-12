# Cycle 18 — Known People service and UI

**State:** COMPLETE for strict local interchange service, controller and UI. Overall 3.0 readiness
remains **IMPLEMENTING** because explicit local-to-cloud reconciliation and broader release gates
remain. No final manual-testing notification is due.

## Source and scope

- Implementation commit: `c87cc63` on `main`, based on cycle-17 commit `85c7080`.
- The change adds strict directory/archive admission, high-level local snapshot preparation,
  production import/export operations, one shared app-lifetime MainActor controller, and matching
  Settings and Expanded Known People presentation.
- Schema-1 legacy ZIP remains a visibly separate additive workflow. Schema-2 import remains a
  complete replacement with an explicit confirmation plan.
- No cloud publication or reconciliation is claimed by this checkpoint.

## Service and transaction behavior

`KnownPeoplePackageAdmissionService` accepts only the exact `.aagedalpeople` directory package or
`.aagedalpeople.zip` archive forms. It rejects unsafe ancestors, links, multiply linked archives,
Finder aliases, suffix/type mismatches and renamed legacy ZIPs. Archive extraction stays in held
temporary storage through strict readback and cleanup. The admitted plan retains source kind,
device/inode evidence and, for archives, exact bytes and SHA-256.

`KnownPeopleService.prepareLocalInterchangeSnapshot` obtains the import lane and whole-root
reservation, drains old deferred work, performs tracked capture or first-time identity assignment,
and requires a final strict recapture before release. Cancellation is FIFO and removes the exact
waiter. Two service instances assigning the same untracked root converge instead of creating
competing identities.

The production adapter retains an opaque admission token until confirmation, keeps one global
request or prompt active, scopes notices to their presenting window and keeps busy state until
cancelled I/O settles. It holds security-scoped access for the full source admission or destination
write, preflights export capacity before identity assignment, and distinguishes a rollback backup
from unresolved recovery. Prompts report current and incoming library IDs and person/sample counts,
including same-library, different-library, untracked, empty and missing-editor cases.

Full-library export requires signed bundle metadata for display name, semantic version, build and an
exact lowercase 40-hex source revision. `scripts/release.sh` injects the current Git revision during
archive creation and rejects archive/app reuse when either the embedded revision or sidecar differs.
Ordinary developer builds without `AAGEDAL_SOURCE_REVISION` fail full-library export before assigning
identity; import remains available.

## UI behavior

The app constructs one controller and injects the same instance into the main window and Settings.
Both surfaces expose directory package import, directory and ZIP export, explicit replacement
confirmation, cancellation/progress, path-aware completion/recovery notices and Finder reveal.
Known People mutations and Settings iCloud controls are disabled during schema-2 interchange.
Stable accessibility identifiers support the dedicated `known-people-interchange` smoke route.
The disposable storage override and iCloud-disabled test default are accepted only with
`--ui-testing`.

## Automated verification

- Focused cancellation lane: 111 tests / two suites pass.
  Log: `/private/tmp/aagedal-people-cancellable-lane-v3.log`.
- Controller and production operations: 17 tests / two suites pass.
  Log: `/private/tmp/aagedal-interchange-controller-v1.log`.
- Controller, provenance and shared presentation: 22 tests / three suites pass.
  Log: `/private/tmp/aagedal-interchange-ui-v1.log`.
- Completed app/Settings integration: 24 tests / four suites pass after correcting one exhaustive
  root-route switch. Log: `/private/tmp/aagedal-known-people-ui-complete-v2.log`.
- Integrated service, routing and UI: 213 tests / 12 suites pass in 31.609 seconds.
  Log/result: `/private/tmp/aagedal-known-people-ui-integrated-v1.log` and `.xcresult`.
- Complete suite: 2,832 tests / 310 suites pass in 110.033 seconds.
  Log/result: `/private/tmp/aagedal-full-known-people-ui-v1.log` and `.xcresult`.
- UI-smoke build-for-testing, project plist, 14 release-metadata validator tests, release metadata
  validation, shell syntax and repository validation pass. The initial workflow build embedded
  `85c708034a3accc2c49711ce1ba217a43069e927`, the exact Git base used for its uncommitted source
  build, and build number 738. A post-commit build-for-testing then embedded exact checkpoint
  revision `c87cc63697abc5ba1267f7ea40bf725b211512e8` and build 738.
- Independent source review approved admission tokens, cancellation settlement, security scopes,
  typed routing refusals, truthful recovery evidence, shared controller ownership, presenter-scoped
  UI and release revision enforcement.

Passing test logs include existing LMDB map-full diagnostic noise; no assertions failed.

## Native computer-use evidence

The source-identical smoke binary was launched with process-only UI-test arguments against
`/private/tmp/aagedal-people-native-os6m18c7/managed`. No user preferences or production Known
People storage were used.

- The dedicated route opened an empty disposable library and exposed the package/archive commands
  plus the separate legacy warning.
- Importing the companion golden directory displayed an untracked replacement prompt with current
  0/0 counts and incoming library `AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA` at 1 person / 1 sample.
  Cancel left the managed projection empty.
- Repeating and confirming replacement installed the library, displayed
  `Åda {persons}` with notes preserved in storage, and retained rollback evidence at
  `.KnownPeople-replacement-4F9B19C7-F536-4AA6-9AFF-5398FA183A00`.
- Directory export produced four files byte-identical to the companion fixture. Their SHA-256 values
  are `9b3f1bb062b98b6482c9e8e0853b440aa88a1203beba738d006330ac04bf794d`
  (manifest), `defe59be76163a68585a9d56a54ab55ffd54385fb72167a400e634f9fd24a901`
  (people), `3135e29a2ba54766bc199d2c9e486aec39b94c66289f098fd26cde9828fb5efb`
  (editor) and `11515e45513a5f28a7e15321d1caa573c3dc1e70a112ac813dd8019f2900f1be`
  (FEM2). Incoming, retained admitted package and directory export all canonical-hash to
  `4fac7fccb730c33e9829d8692f4652a6bfb8d1538ab5022ea750f0515bb59d09`.
- The managed projection recomputes to
  `2fc2b10bb1010ea276342618984a13261b410ac67ff265c98ccd5d87d52b3264`,
  exactly matching the installed state record.
- ZIP export produced a 5,142-byte archive with SHA-256
  `dbb1ca148571977ecb4f034f89dad8139cdabe2e9db43a2781a2bb8269ec3698`.
  It contains the same four sorted, unencrypted root entries, all method 0/STORED with deterministic
  1980-01-01 timestamps, and Python `ZipFile.testzip()` returned no error.
- Reimporting the same package displayed matching current/incoming library IDs and 1/1 counts.
  Cancel preserved the installed library. The app then quit normally and native inventory showed
  no running Photo Agent test process.
- The post-commit smoke app carrying the exact `c87cc63` revision launched directly into the
  disposable Known People route, displayed the installed 1/1 library and exact Unicode/braces,
  and quit normally. No Photo Agent test process remained.

## Remaining work

1. Add an explicit, generation-safe local-to-cloud reconciliation workflow before iCloud can be
   enabled for a replaced or newly assigned local library.
2. Coordinate and test the 65,534-entry ZIP32 limit in FTP Sync; directory packages retain the
   larger schema inventory limit.
3. Broaden native coverage to archive import, relaunch, Settings cross-window arbitration,
   accessibility/IME/display and realistic large-volume failure/cancellation cases.
4. Complete production AuraFace distribution trust and legacy embedding provenance disposition.
