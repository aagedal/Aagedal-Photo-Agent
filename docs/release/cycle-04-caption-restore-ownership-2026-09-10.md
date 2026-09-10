# Coordinator cycle 4 — explicit metadata restoration and ownership

**Started:** 2026-09-10 08:46 UTC, Europe/Oslo.
**Baseline:** `ff41d5e` on `main`; clean checkout, latest implementation `914e996`.
**State:** bounded implementation committed and verified; broader release gates remain open.
**Implementation commit:** `43ddf32e12c26d437598a565878c431b118fc251`.

The active task inventory showed no other task editing this checkout. Media Player work was
active in its separate repository; its source and processes are outside this cycle. The
coordinator owns builds, native testing, integration and commits. One sub-agent owns Restore/
history and pending-field state; another owns metadata carrier ownership and Duplicate. Their
shared service edits are sequenced at a checkpoint, and an independent reviewer will inspect
the integrated changes. All source criteria remain open until their actual gates are proven.

## Native baseline reproduction

`build/qa-caption-restore-cycle4/` contains the generated 640×400 PNG, synthetic JSON original
headline/caption A, pending headline/caption B, two exact history entries and XMP mirroring B.
The initial hashes are in `fixture-manifest.json`. No private photo or metadata was used.
The pre-fix build is the cycle-3 tested Debug 3.0.0 (738), whose hashes and exact bundle path
are recorded in [the Caption follow-up](cycle-03-caption-baseline-2026-09-10.md).

Using native CUA, the coordinator opened the folder and selected `restore.png`. The editor
showed `Edited headline B` and `Pending caption B`, with no field-level pending markers.
Editing History correctly displayed both A → B changes and the Original State / Before edits
action. Clicking Original State left both displayed values at B. Filesystem inspection then
confirmed `pendingChanges: false`, metadata B and **snapshot B**, while XMP remained byte-exact B.
The prior original snapshot A was overwritten without restoring its text. This reproduces an
actual product defect rather than relying only on source inspection. A copy of this defective
result is saved as `baseline-after-original-state.json` in the ignored fixture folder.
The QA app was quit before source integration.

Fresh fixed-build cases are prepared in `build/qa-caption-restore-cycle4-fixed/`: Original
State, intermediate history, and a legacy record with no original snapshot. Each has its own
PNG, mirrored XMP, JSON and original-hash manifest. They reconstruct known synthetic A/B
values explicitly; the overwritten baseline fixture is retained as failure evidence.
`build/qa-sidecar-ownership-cycle4/` contains a synthetic JPEG/PNG shared stem whose legacy
JSON belongs only to the JPEG, plus a Duplicate case with an opaque nested JSON extension.
The JPEG comes from the repository's generated analysis corpus; all original hashes are saved.

## Required correction boundaries

Explicit restoration must retain a trustworthy original snapshot, make a coherent pending
editorial draft, update its descriptive XMP mirror without undoing Develop/orientation, and
report partial persistence accurately. Historical states require validated exact transitions;
trimmed, summarized, unknown or inconsistent history must not invent an original state.
Repeated restoration, failed mirror retry, selection switches and relaunch need evidence.

The ownership audit identified permissive legacy reads, ordinary save/migration/deletion of
sibling-owned legacy JSON, and Duplicate retaining the original photo's `sourceFile` in its
new sidecar. Fixes must preserve opaque extension fields, skip and retain proven foreign
legacy records, fail closed for ambiguous ownership and keep current/legacy precedence stable.
Serialized transactions alone do not prove ownership. Source, destination and late-arrival
cases require focused regression coverage.

## Implementation and independent review

Restore now uses an identity-matched saved original snapshot and validates retained history
before reversing later exact transitions. It commits a pending editorial draft and its exact
descriptive XMP mirror under one photo lock, preserving current Develop/orientation. A dedicated
compare-and-replace operation avoids replaying later deltas over the chosen restore target.
Stale state, failed mirrors, committed-but-unverified JSON, cancellation and selection changes
receive distinct guarded outcomes. Original State is available with an empty log when a saved
snapshot exists; missing snapshots disable that action. Legacy duplicate history identities use
the clicked retained index with full history comparison. New events carry optional persisted
UUIDs and actual event timestamps. Legacy payloads, equal-time order and unknown event fields
are preserved by history merging. Restore follows the existing privacy policy: summarized or
redacted transitions cannot be reversed safely, including later caption restoration deltas.

Metadata carrier reads now check directory/file type and explicit owner without automatically
quarantining unreadable records. Proven foreign legacy carriers stay untouched and are omitted
from the requested photo's metadata; ambiguous ownership or a mismatched current carrier fails
closed. Saves, migration, selected deletion and rename preserve that ownership boundary. Duplicate
copies the raw owned JSON graph with deliberate destination naming, preserves source extensions,
reserves orphan carrier names and reports partial photo/metadata outcomes accurately.

Independent review found and drove corrections for nil localized-title restoration, JSON commit
evidence, cancellation busy-state ownership, empty-history access, duplicate legacy indices,
equal-second event ordering and a late destination collision when no source sidecar exists.
The final source review found no new blocker in these bounded corrections. The app-only build
passed; focused and integrated tests plus fixed-build native checks are recorded below when complete.

## Remaining integrity boundaries

The review also identified a **separate pre-existing stale FIFO replay defect**: after draft
event A → B is already installed, another writer saves independent field C; retrying the old
draft has no new history identity and the generic merge can replace current metadata with the
old complete record, losing C. A blanket keep-current change would break supported Develop-only
and successful Write-completion saves, which can have no descriptive history delta. Fix this
next with explicit edit-replay versus technical/write-completion intent and exact-record CAS
before clearing pending state. Audit `CaptionDraftPersistence.persist`, `MetadataViewModel`'s
write completion and `saveSingleImageSidecar`, and the shared persistence service. Include both
JSON-already-committed/XMP-failed retry and intervening independent edits, preserving Develop,
orientation, original snapshots and pending status. This finding is not deferred to human
acceptance and the release remains unready.

Migration/rename deletion still has a narrow final external-writer window between byte checking
and source unlink. The changes establish observed-token and app-serialized protection, not
race-proof transactions against arbitrary external writers or process-crash atomicity. Staging
cleanup is best-effort; physical-volume/crash evidence remains open. No retrospective repair of
an already overwritten original snapshot is attempted.

## Automated validation

The first focused run compiled and executed 151 tests in eight suites, reporting 18 issues.
Twelve assertions incorrectly expected technical CRS/orientation in editorial-only JSON or
compared normalized XMP against an unnormalized fixture; the corrected test asserts those
values in the actual editor and parsed XMP before and after two reload/Restore cycles, while
confirming JSON intentionally omits them. Two issues exposed lost pre-admission cancellation:
the photo coordinator deliberately completes admitted operations in an unstructured task, so
Restore now checks cancellation before admission. A separate test verifies late cancellation
still reports an already completed durable restoration accurately. Four issues exposed bulk
lookup comparing different Foundation URL representations of the same path; canonical path
comparison fixes discovery while retaining exact carrier names and explicit ownership.

The corrected focused command included `MetadataEditorReadServiceTests`, `MetadataHistoryTests`,
`MetadataSidecarServiceTests`, **`MetadataCarrierOwnershipTests`** (missing from the first run),
`SourceImageRevisionTests`, `CaptionSessionTests`, `ApplicationTerminationFlushCoordinatorTests`,
`FileSystemExecutorTests` and `RejectMoveServiceTests`. It passed **164 tests in nine suites,
5.735 seconds**, with `TEST SUCCEEDED`, using the protocol's Xcode test command plus one
`-only-testing:'Aagedal Photo Agent Tests/SuiteName'` argument per suite. Logs:
`/private/tmp/aagedal-coordinator-cycle4-focused.log` and
`/private/tmp/aagedal-coordinator-cycle4-focused-v2.log`. The independent reviewer inspected the
corrections and found no new blocker. Full-suite and fixed-build native results follow below.


The first unfiltered integrated run passed **2,474 tests in 279 suites, 87.939 seconds**
(`/private/tmp/aagedal-coordinator-cycle4-full.log`, `TEST SUCCEEDED`). Repository validation
also passed (`/private/tmp/aagedal-coordinator-cycle4-repository-final.log`). Native testing then
exposed additional UI integration defects, so those passing results do not validate the later
corrections until the following rerun.

## Native integration findings after the first passing suite

Original State visibly restored A in Browser, and immediate read-back showed pending JSON A,
snapshot A and XMP A. Repeating the action retained those values. Missing-snapshot Original State
was disabled with an explanatory accessibility hint. However, field markers still disappeared
for mirrored B drafts: the aggregate comparison had been corrected, but the actual field helpers
still used XMP B and the saved baseline was excluded from observation. History rows were only
selectable list rows in accessibility; AX click, Return and a visible-row coordinate click did
not activate restoration. The follow-up unifies every field helper on the saved baseline,
makes baseline updates observable, labels pending indicators and uses explicit history buttons.

A later hash comparison found `original.png` had gained embedded XMP A (IDAT pixel bytes were
unchanged), and JSON was subsequently marked written. Selection/deactivation lifecycle callers
used overall `hasChanges` as an automatic-write trigger, bypassing the panel's unpersisted-edit
guard. Merely leaving an already saved/restored draft could therefore write it into the image.
This contradicts the promised pending-until-Write behavior and is being corrected before native
retesting. The original failed fixture and `after-original-restore-manifest.json` are retained.

The initial ownership UI run confirmed `shared.png` starts blank, a real Caption headline edit
creates its own record, and `shared.jpg` retains its JPEG-owned legacy headline/caption; all six
original fixture hashes were exact at that checkpoint. Duplicate correctly chose
`duplicate copy 2.png`, avoiding the reserved orphan, and its JSON owner/opaque nested graph
were correct. The same lifecycle bug then wrote the old selected source PNG/JSON during the
selection change. A fresh final native fixture run is required; this is not a passing claim
for source immutability yet.


The lifecycle fix admits automatic configured-mode saves only for actual unpersisted editor
changes. Caption deactivation captures buffered text through its registered FIFO instead of
embedding it; failures surface without an embedded-write fallback. Explicit Write stays separate.
Removing an unnecessary outer selection Task improves old-selection admission for the tested
single-photo path; it does not establish all batch/history-only selection capture safety.
Independent review found no blocker in the native follow-up. New lifecycle tests exercise real
pending/restored records and byte preservation across navigation, deactivation and termination,
real Browser edit admission, buffered Caption FIFO persistence and failed capture.
Fresh final fixtures in `build/qa-caption-restore-cycle4-final/` and
`build/qa-sidecar-ownership-cycle4-final/` reconstruct the synthetic records and preserve original
image bytes. Both have their own initial hash manifests; previous failure evidence remains intact.


## Final native observations and temporary host limit

The corrected focused run passed **129 tests in eight suites, 3.112 seconds**, with
`TEST SUCCEEDED` (`/private/tmp/aagedal-coordinator-cycle4-focused-v4.log`). It covered editor
reads/Restore, history, sidecar service, carrier ownership, automatic lifecycle, Caption FIFO,
termination and source revision. The preceding v3 build failed on Swift's default throwing
closure argument; the coordinator made `captionFlush` explicit at both nonthrowing call sites.
No force-try or error suppression was introduced.

Final native Restore verification on the fresh `*-cycle4-final` fixtures:

1. Browser showed orange Headline and Description markers for mirrored pending B, with explicit
   `Headline: changes pending` / `Description: changes pending` accessibility labels.
2. Original State restored A, and repeated Original State stayed A. Navigating to another photo
   retained pending status and left the source PNG byte-exact. The markers cleared because A
   equals the saved original; overall Pending correctly remained.
3. The explicit `Restore Description history point` button was present and activatable through
   AX. It restored Headline A / Caption B, preserving snapshot A. Repeating the same retained
   point stayed stable; only Description's pending marker remained.
4. The legacy record's Original State action was disabled with its missing-snapshot explanation.
   All three legacy fixture files stayed byte-exact.
5. After normal quit and confirmed termination, a full relaunch/reopen displayed both restored
   states correctly. Caption displayed Headline A / Caption B with its Description marker and
   overall Pending; selecting Original displayed A/A. Focusing/leaving the fields, hiding the
   app with Cmd-H (deactivation), and quitting introduced **no changes to any of the nine files**
   relative to `after-restore-manifest.json`. `after-relaunch-manifest.json` records the same
   hashes. Both restored records retain `pendingChanges: true` and snapshot A. Every source PNG
   matches the initial manifest; only the two intentionally restored JSON/XMP pairs changed.

Final ownership verification again showed the PNG initially blank and the JPEG's own legacy
headline/caption intact. A real Caption edit created `shared.png.meta.json` with owner
`shared.png`, pending status and `Independent PNG headline`. Returning to Browser and selecting
Duplicate's source left all six original fixture files byte-exact. The final Duplicate action
could not be completed: native menu references became unreliable, then CUA explicitly reported
**the Mac is locked and automatic unlock could not unlock it**. At that lock checkpoint, no duplicate output existed in
this final folder. The earlier native run proved copy naming/owner/opaque content, but its source
immutability was confounded by the now-corrected lifecycle bug; recheck final Duplicate and
ownership relaunch once host access resumes. `after-caption-edit-manifest.json` preserves this
checkpoint. Do not count a blocked action as a pass or request user intervention while useful
independent release work remains.

Earlier transient menu references were recovered with a CUA session reset and fresh complete
AX trees; no security policy or lock was bypassed. The Restore test app was confirmed stopped
before starting ownership testing. The ownership session was still open when the Mac locked;
final UI closure could not be confirmed. No Finder or other application content was changed.


## Final integration and handoff

The final unfiltered protocol command passed **2,479 tests in 280 suites, 92.086 seconds**, with
`TEST SUCCEEDED` (`/private/tmp/aagedal-coordinator-cycle4-full-v2.log`). This includes every
cycle-4 source correction. Repository validation passed
(`/private/tmp/aagedal-coordinator-cycle4-repository-v4.log`) and whitespace checks passed.
The tests completed despite the native host lock. No source change followed these checks.
The source was committed locally as `43ddf32e12c26d437598a565878c431b118fc251`; initial native testing
used identical uncommitted source; resumed Duplicate/relaunch checks used the same source after
commit. No push or release was performed.

Tested Debug app: **3.0.0 (738), arm64**, macOS **27.0 (26A428)**, SDK **26.5**. Bundle:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
SHA-256:

- `Contents/MacOS/Aagedal Photo Agent`: `caa7972089e943baea21f88baa937867b4308009079c27c594bedfe8f702b529`
- `Contents/MacOS/Aagedal Photo Agent.debug.dylib`: `44dd0cf648a966111eb173e47d2626a0001b2a419ae330183bc06ceb7afdb2d9`

Independent source review found no new blocker in the bounded corrections. Document audit
confirmed all 61 baseline gate criteria remain verbatim and open, 29 complete unique HTML
cases (14 agent, six user, nine external), valid local links and valid JavaScript syntax.
The checklist now specifies Restore/lifecycle/source-byte/ownership expectations. Its visual
browser validation, exact candidate binding and all human results remain pending. The broad
3.0 criteria are not closed by this slice. The resumed native checks below complete this bounded slice. Address the distinct stale FIFO
replay defect described above before archive/reassociation and transcription work. No-progress count remains zero; automation stays
active and readiness is **IMPLEMENTING**.


### Native access resumed and Duplicate verification completed

At 10:47 UTC, the coordinator rechecked CUA after completing independent validation and source
commit work. Native access had resumed. Duplicate now executed on the final fixture, selected
`duplicate copy 2.png`, and displayed the source headline/caption. Read-back confirmed all six
original fixture hashes unchanged, the duplicate PNG byte-exact with its source, destination
`sourceFile` correct, nested opaque JSON extension preserved and pending status retained.
The reserved orphan JSON stayed byte-exact. `after-duplicate-manifest.json` records all ten
image/sidecar files. After a normal quit, confirmed termination and full relaunch/reopen,
Duplicate displayed its own metadata, JPEG retained its legacy text and PNG retained only its
independent headline. Normal navigation and quit left all ten files byte-exact against that
manifest; `after-relaunch-manifest.json` records the same hashes. Native inventory confirmed
all Photo Agent processes stopped. The temporary host lock no longer blocks this slice and no
user action is pending for it. The source and test results are unchanged.
