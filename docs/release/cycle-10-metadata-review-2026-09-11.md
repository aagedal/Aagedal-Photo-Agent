# Cycle 10: retained Metadata Review saves and recovery

Status: implementation `f897bdd08e9dd8efab6ca9de7f626080cbc99736` passes full validation,
independent source review and the native happy path. Native failure/recovery coverage remains open. This is not a release readiness decision.
The previous implementation `b5840e4304450dce9371b5c2329e230635adf351` passed 2,569 tests;
its separate native rotation evidence is in [the rotation report](cycle-10-rotation-native-2026-09-11.md).

## Intended behavior and acceptance

Metadata Review must retain complete editorial drafts outside the lifetime of individual lazy
rows. Capture must include the focused field before workspace exit, folder changes, normal quit,
and file or bulk metadata mutations. Unchanged rows must cause no writes. Accepted edits enter
the shared durable FIFO with exact per-request completion receipts. Failed JSON/XMP saves retain
requests; an external-change conflict requires visible, photo-scoped recovery and verified export
before explicit discard. An existing missing original snapshot stays missing.

The first Review draft for a photo without app JSON requires captured source and XMP evidence.
A partial JSON commit must not make retry silently adopt later physical changes. This new
creation-evidence requirement is specific to Review capture; it does not imply that all older
Caption entry points have gained the same guarantee.

## Integration ownership

- Core agent: replay creation evidence, exact installed receipts, shared queue admission and core tests.
- UI agent: retained Browser row state, Review editing and scoped recovery, direct mutation admission and caller tests.
- Coordinator: workspace/folder/command save barriers, lifecycle regression tests, integrated builds,
  native testing, evidence and local commits.
- Independent reviewer: persistence and transition audits; final integrated review remains required.

Review already identified and corrected parent call-site gaps for folder close, Activity resume,
full-screen Compare, rename, duplicate, Trash, bulk reset/removal, variables and Write All Pending.
The final source passes compilation and focused behavioral checks; native coverage remains open.

## Native fixture plan

Prepared ignored fixtures at `build/qa-metadata-review-cycle10/{happy,failure}`. Each folder has
four synthetic PNG copies: `a-known`, `b-null`, `c-first`, and `d-untouched`. The first two have
owned pending JSON with known and absent original snapshots; the latter two have no app JSON.
Their origin is the synthetic rotation fixture, with metadata-only copying and no user photos.
`initial-manifest.json` records all 12 initial image/JSON files.

Exercise multiple edits and the last focused field across row recycling, workspace exit and
normal quit/relaunch. Read JSON, XMP, source hashes and retained original snapshots. Use only the
failure folder for a disposable XMP obstruction; remove the obstruction before retry. Preserve
untouched-file hashes. Record actual paths covered and keep unexecuted cases visibly open.

The HTML checklist's A03 now includes these Review acceptance steps. Static validation passes:
31 unique cases, all required descriptions and local source links present; 16 agent, 6 final-user
and 9 external/hardware cases. This static check does not establish browser interaction or any
case result.

## Automated validation

The app build passes after adding the missing UniformTypeIdentifiers import. Initial focused
compilation found three test-only issues: two nested throwing capture calls needed explicit
`try`, and a semaphore wait needed an asynchronous continuation. After those corrections,
**57 tests in five suites pass in 1.387 seconds**: CaptionSessionTests,
CaptionConflictRecoveryTests, MetadataReviewPersistenceTests, FieldMutationCallerTests, and
MetadataAutomaticSaveBoundaryTests. The full suite passes **2,585 tests in 286 suites in 93.600 seconds**. Repository validation
and whitespace checks pass. The ten source/test files are committed as `f897bdd`.

Independent source review passes after correcting stale rendered-row writeback, full-value live
Description rebasing, and photo-scoped recovery freeze ownership through asynchronous begin,
discard, view disappearance and remount. The last view-lifetime path is source-reviewed, not yet
native-tested. Six new Browser caller methods and nine new core methods cover the remaining
buffer, provenance, receipt, replay, recovery and mutation-admission cases.

Logs: `/private/tmp/aagedal-coordinator-cycle10-build.log`, `-build-v2.log`, `-focused.log`,
`-focused-v2.log`, and `-repository.log` (all share the same cycle10 prefix).

## Native verification on the committed implementation

Tested Debug app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`,
version 3.0.0 (738), arm64, macOS 27.0 (26A428). Source is `f897bdd`; only documentation
was dirty. Exact binary identity is in `build/qa-metadata-review-cycle10/tested-binary-identity.json`:

- Executable SHA-256: `c3a2724e88f1b5eb1732a762edd19ead84731900409a6b0c3332f7fae645c056`
- Debug dylib SHA-256: `fd91d6be19edf06f9436b708f6b18131f9eea14a0943d517196295afac1213ff`
- Preview dylib SHA-256: `42820d2cb1a482533e38853903552ddc9fc762cf1d7014a10f15f24d0706c5ee`

Using native computer use, opened the happy fixture folder and selected Metadata Review.
Entered `Review native known headline K10` and a full sentence Description for a-known;
entered `Review native null snapshot N10` for b-null and `Review native first record C10`
for c-first. Clicked Back to Browser while the last field was still focused.

Read-back PASS: all three JSON records and XMP headlines contain the accepted edits. a-known
retains its original F snapshot; b-null retains no original snapshot; first-record c-first
captures original F. All are pending drafts. All source PNG hashes are unchanged. d-untouched
has no JSON or XMP record. The known Description retains its full text and spaces.

Reopened Review, changed b-null to `Review normal quit focused text N11`, and immediately
issued normal Command-Q with its field focused. Native inventory subsequently showed every
Aagedal Photo Agent entry stopped. JSON/XMP contain N11 with its original still absent.
Relaunched the same binary, reopened the same folder and Review, and observed K10, N11 and C10
in both accessibility state and an inline screenshot. The complete before/after relaunch
artifact snapshots match. History counts are 2, 2 and 1 respectively; reopening adds no history.

Evidence in the ignored fixture root: `happy-after-workspace-exit-snapshot.json`,
`happy-after-quit-snapshot.json`, `happy-after-relaunch-snapshot.json`,
`happy-after-final-shutdown-snapshot.json`, `initial-manifest.json`. The final shutdown snapshot
also matches the verified post-quit artifacts.
Inspector: `build/qa-rotation-cycle9-tools/inspect.py`. The screenshot was observed inline;
no standalone screenshot file was saved. This is narrow happy-path evidence, not a pass for
all A03 cases, >20 native fields, row recycling, IME or recovery lifetime cases.

## Native limitation and cleanup checkpoint

While opening the failure folder, native menu element IDs became invalid, subsequent window
state was blank/stale, and screenshots returned unavailable. Reconnecting did not restore a
usable window. Open Folder/Go To may still be pending. Escape twice and normal Command-Q were
requested, but native inventory still showed the QA app running; shutdown was initially **not confirmed**.
A later normal Escape/Command-Q retry succeeded: final native inventory showed every Aagedal
Photo Agent entry stopped. The earlier unconfirmed shutdown was resolved before handoff.
No write-mode preference was changed in this Review session. Previous rotation preferences had
already been restored. All six failure fixture files still match the initial manifest; there
are no extra files and no XMP obstruction was created.

On the next usable desktop connection, relaunch the identified binary and run failure/retry
and photo-scoped export/discard tests in the separate failure fixture.
Do not claim these native cases passed from the automated tests. Review accessibility currently
exposes validation text as the field Value and actual text in Help; include that existing behavior
in the required VoiceOver audit. No credentials, production destinations or user photos were used.

## Remaining gates

Native partial-save retry, conflict export/discard and disappearance/remount must still be
exercised. Broader writer completion, variables, archive/transcription, hardware, external
interoperability and release prerequisites remain tracked in readiness.md. The automation stays
active; the app is not ready for final user acceptance.


## Cycle 11 continuation

[Native cycle 11](cycle-11-review-recovery-native-2026-09-11.md) subsequently passes ordinary
partial-save retry, cancellation, verified export and scoped discard through normal relaunch on
the same f897bdd binary. Its final shutdown is confirmed; remaining IME/accessibility and
in-flight disappearance cases stay explicit.
