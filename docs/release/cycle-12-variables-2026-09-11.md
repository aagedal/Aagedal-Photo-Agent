# Cycle 12: immutable variable processing and verified persistence

Implementation **`fbe253f11304f9f8de8cfafa667338edfd580781`**, from clean `e9e6a14`.
Independent review, focused checks, integrated tests and repository checks pass. Native physical
completion/failure/repair and History Only persistence pass on that exact binary. Preferences are
restored and all QA app entries are stopped. Other active tasks use separate repositories.

## Defects and correction

The previous selected-image path counted success immediately after fire-and-forget commit.
The folder path could read mutable folder/policy after awaits, write only interpolated scalar
differences, then acknowledge the entire pending record. It promoted known/null originals,
trimmed replay history early and omitted GPS/sports preprocessing from some deltas. Unreadable
individual inputs and cancellation could produce misleading counts or stale UI.

The correction captures inputs/policies/identity and resolves a local metadata copy for selected
and nonselected photos. It prepares full untrimmed changes through awaited JSON-only replay;
physical modes then verify the complete resolved editorial record with exact source/JSON/XMP
ownership. History Only changes no XMP/image. Same-session retry retains immutable resolved
requests, own partial physical receipts and full history IDs; final unverified JSON completion
can be verified read-only without writing again. Independent newer records remain conflicts.

Review also required preserving literal list punctuation, respecting Develop-only XMP and
completed-versus-pending JSON reference semantics, avoiding stale selected-editor overwrites,
keeping buffer-only processing separate from folder task ownership, and showing preparation
commit uncertainty. Core source review passes its corrected first-attempt and retry contracts;
caller/lifecycle source review also passes after corrections, including real-transformation/zero-replay-
delta preparation. An independent final recheck of parent lifecycle/UI integration passes.

## Lifecycle and retry scope

Variable admissions may own the only copy of unsaved selected/template edits before their first
JSON write. Those inputs and original policies must remain retained through asynchronous failures,
and a shared lifecycle guard prevents ordinary Close/Quit from losing unverified work. Retry
remains reachable outside that guard. Once resolved JSON is verified, its editorial values/history
survive relaunch. The original variable policy and in-memory receipt do not persist across restart:
a later Write All is a new explicit operation, never an automatic resume of the earlier policy.

## Fixtures and checklist

New core/caller tests are explicitly registered in the Xcode test target; production Models/Services
use the synchronized app root. Parent added an isolated shared-lifecycle integration test to
CaptionSessionTests.
Static HTML validation passes: 33 unique complete cases (18 agent, 6 final-user, 9 external),
all source links resolve, and extracted JavaScript passes `node --check`. Browser interaction
remains separately unverified.

Disposable fixtures: `build/qa-variables-cycle12/{physical,history}`, copied from generated QA
PNGs and owned JSON/XMP. Known/null originals, filename substitutions, unrelated pending captions,
history, opaque JSON and comma/semicolon list tokens are included. Physical C has an intentional
empty XMP directory obstruction. Initial artifact hashes and parsed snapshots are recorded. Native outcomes appear below.

The separate legacy mask-equality defect inventory is in
[field-write design](field-write-completion-design.md): three single-photo/Develop callers still
need exact XMP bytes retained at editor load. No authoritative release checkbox is closed by this
bounded work. HTML case A18 describes the variable acceptance matrix with results unrun.

Permanent retained pre-prepare conflicts currently have no scoped export/reconcile/discard action.
Ordinary Close/Quit remains blocked safely while the only copy is unverified; Retry cannot repair
all ownership conflicts. This is mandatory subsequent recovery work before release, not a passing
recovery gate or an invitation to discard work. Explicit Quit Without Saving is not the planned
safe recovery workflow. No readiness or broad feature completion is claimed.


## Automated validation checkpoint

Focused v4 passes **134 tests in seven suites in 7.267 seconds** (exit 0), using the new variable
core/caller/lifecycle suites plus pending-write, replay, editor-read and interpolator regressions.
Log: `/private/tmp/aagedal-coordinator-cycle12-focused-v4.log`. Earlier compile/fixture/product
failures and the intentionally interrupted v3 are recorded below; no assertions were removed.
Independent final review passes. Full v2 passes **2,633 tests / 291 suites in 99.012s** (exit 0).

The first integrated run completed **2,633 tests / 291 suites in 103.309s** with one failed
source-layout assertion in `MatchRosterServiceTests.callerSourceContract`: roster loading moved
from MetadataViewModel to VariableMetadataBatch. The source contract now reads the resolver,
retains the awaited/shared-loader check and checks the resolver’s cancellation-result guard. No
production correction was needed for this failure. Focused roster validation passes seven tests in 0.082s; full v2 subsequently passed.
Repository validation passed (exit 0); log `/private/tmp/aagedal-coordinator-cycle12-repository.log`.


### Earlier failures and corrections

- First focused build failed on test actor isolation and a missing `try`; test-only fixes retain assertions.
- Focused v2 ran 131 tests / seven suites with three issues across two tests. A real instant-template
  bug dropped explicit organisation lists when no previous common baseline existed. Explicit list
  intent now survives independently of that baseline. The other test used invalid Country Code
  `Resolved 17`; `NOR` and a valid date preserve all 21 intended changes and full-result equality.
  A separate invalid-country regression proves failure leaves source and JSON bytes untouched.
- Focused v3 was deliberately interrupted after review found template append could replace prior
  unsaved clear/overwrite intent. Append now extends the final replacement list, preserving removals;
  untouched/append remains additive. Actual batch API regressions cover clear, overwrite, distinct
  per-photo append and explicit empty replacement. Independent review passes.

Logs are `/private/tmp/aagedal-coordinator-cycle12-{focused,focused-v2,focused-v3,focused-v4,roster-focused,full,full-v2,repository}.log`.


## Native identity and observed results

Debug 3.0.0 (738), arm64, macOS 27.0 (26A428), on the committed source above with no dirty
application/test files. App: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
The binary manifest is `build/qa-variables-cycle12/tested-binary-identity.json`:

- Executable SHA-256: `15c5436fc5e33d3762ce29a0bcc1550984454947e4ffb8070010ba72ad18538d`
- Debug dylib: `aa04fe4f761a7dd674ea1a7dc0e5a357b646daa9feae48c598c5fb2f63c2bc2a`
- Preview dylib: `0cbf2782be045d526989d243c6516cb5a8345f79145133c2362587d3a86781bb`

1. Opened `physical` using native Open Folder; Professional was the original preference. Clicked
   Process Variables in Folder. Complete native Details reported **2 of 3 completed**, identified
   C's unreadable XMP obstruction and explained session-only retry. A/B wrote resolved headlines
   and unrelated pending captions; C's image and JSON remained exactly unchanged.
2. Removed only the intentionally empty C XMP directory. Clicked the visible Retry Variable Writes.
   C completed and its pending marker disappeared. A/B source/XMP/JSON remained byte-for-byte equal
   to their already completed state: no rewrite or duplicate history.
3. Via native Settings, selected Custom / Standard Images / Save History Only. Processed `history`.
   All three JSON records contain resolved headlines and pending=true, with known/null originals,
   opaque JSON and history preserved. Every PNG and existing XMP is byte-identical to baseline;
   the absent C XMP remains absent. Selected B displayed the resolved headline, unrelated caption,
   comma/semicolon keyword/person tokens and pending markers; screenshot inspection passed.
4. Restored Custom Standard Images = Write To Image File, then Professional and the General page.
   Captured write preferences compare exactly equal to their original values; RAW/C2PA were not changed.
5. Normal quit, inventory-confirmed shutdown and relaunch: reopened history and selected B; pending
   markers and resolved fields persisted. Reopened physical in another normal launch and selected
   repaired C; completed markers and resolved values persisted. Both folders' full parsed/hash
   snapshots match their pre-relaunch completion states. Final normal quit and inventory show all
   Aagedal Photo Agent entries stopped.

All six records retain exact known/null original values, opaque `preserve:[1,2,3]`, literal
`Doe, Jane`, `Alpha;Beta`, `Documentary, test` and `Unchanged;item`, unrelated caption and exactly
one added history event (2→3). Physical mode preserves PNG pixel payloads and verifies complete
editorial values in embedded and any existing companion XMP; C gains no unnecessary XMP.
The artifact verifier initially indexed an omitted nil snapshot as a required JSON key; it was
corrected to treat omitted and null as the same unknown value, retaining the equality assertion.

Evidence: `build/qa-variables-cycle12/{fixture-origin.json,*-before-snapshot.json,physical-partial-snapshot.json,*-complete-snapshot.json,*-relaunch-snapshot.json,write-preferences-before.json,write-preferences-restored.json,verify.py}`.
Checks: `python3 build/qa-variables-cycle12/verify.py physical` and `... history` both pass all
three photos; separate snapshot comparisons prove completed A/B no-write retry and relaunch equality.

A transient native menu state returned invalid element IDs and no screenshot. Session reconnect
alone did not clear it; normal quit/inventory/relaunch restored Settings and screenshots. No
permission/lock bypass was used. Command-O attempts did not open a chooser during the session;
explicit Open Folder after relaunch did. This does not supply shortcut acceptance evidence.

Still unverified here: focused live-field commit, native >20-field template, actual in-flight
cancellation/selection races, authentic RAW/C2PA, broader performance/accessibility, and permanent
conflict recovery. Unit coverage is not substituted for these native gates. All 60 authoritative
open criteria remain open; no final acceptance candidate or readiness notification is issued.
