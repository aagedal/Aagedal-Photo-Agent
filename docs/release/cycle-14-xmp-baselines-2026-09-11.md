# Cycle 14: exact editor XMP baselines

Implementation `a777dd78c1b7e6ecac6eaa8be6aa59de882ae571` passes independent source review,
121 focused tests / five suites (4.825s), 2,666 integrated tests / 295 suites (96.165s),
repository validation and whitespace checks. Native repeated masked saves, genuine external
conflict refusal, deliberate reload/retry, embedded-plus-XMP reset and relaunch pass.

**Known unresolved release blocker:** after a genuine failed Develop save, dismissing its
error then pressing Command-Q exits without a retry/discard decision or durable retention of
the unsaved edit. This is reproduced on both the old and new binaries. The token fix does not
close failed-save lifetime; it is the next implementation priority. State remains IMPLEMENTING.

## Scope and review

Started clean at `1ca6bce`, with verified implementation `9c344fb`. All four authoritative plans
retain 60 open criteria (9 audit / 23 investigation / 22 journalistic / 6 solar). Other desktop
tasks were idle in separate repositories. Caller agent owned MetadataViewModel and new caller
regressions; core agent owned read facts and additive verified replay/Restore receipt propagation.
Coordinator owned project, documentation, integration and native testing. Independent reviewer
audited load/publication/receipt paths and final changes.

Three single-photo/Develop save paths now use exact XMP bytes captured with the editor load,
including explicit absence. Unavailable, undecodable or raced evidence refuses writes; Save-time
reads validate the old baseline and cannot adopt external changes. Parsing displayed metadata
uses the same captured bytes on the dedicated filesystem executor. This removes false conflicts
from newly generated mask IDs without weakening content-change detection.

Review found and corrected a fourth mask-equality admission in Restore/history. Restore now
accepts loaded exact bytes and returns a verified installed token; post-install failures report
an actual XMP write without claiming verified completion. Final JSON and XMP checks protect
against external replacements after hooks. Replay also publishes its token only after final
owned JSON and XMP validation.

Caption and Variables can intentionally preserve independent external technical settings.
Their receipt must not authorize a later Develop write using old editor settings: promotion
compares cached raw CRS, app-private technical properties and orientation, avoiding regenerated
mask IDs. A mismatch invalidates the token with a reload message. Same-load/photo/folder checks
protect asynchronous publication. RAW Caption paths lacking a verified new token conservatively
require reload; embedded-only cleanup preserves its prior XMP evidence.

Snapshot semantics are unchanged: pending History Only saves preserve known/null originals;
explicit completed writes establish the documented written-image baseline. No original-snapshot
redesign or broader parser-policy change is included.

## Automated results and failed attempts

Used Debug `Aagedal Photo Agent Tests`, destination macOS, serial execution. Focused selection:
MetadataEditorXMPBaselineTests, MetadataEditorXMPSnapshotTests, MetadataEditorReadServiceTests,
MetadataSidecarServiceTests and VariableMetadataCallerTests. Full run removed those filters.
Project plist, `scripts/ci/validate_repository.sh` and `git diff --check` pass.

- Initial focused build exited 65 before tests: three optional mask-count assertions lacked
  optional chaining. Corrected syntax still requires exactly one mask; nil fails.
- Focused v2 ran 121 tests / five suites with two issues in the new replay fixture. Its manual
  `Title` event did not match production `Headline` changes, correctly preventing the mirror.
  The fixture now uses production full-change capture and a saved baseline. Both variants prove
  an actual XMP write; failure also proves the post-write external replacement persisted before
  checking that no verified receipt was published. No early failure substitutes for final checking.
- Focused v3 passes 121 tests / five suites in 4.825s. Full passes 2,666 tests / 295 suites in
  96.165s. Existing file-backed fixture readers now use production load-time evidence; no
  assertions or deliberately unavailable-evidence tests were weakened.

Logs: `/private/tmp/aagedal-coordinator-cycle14-{focused,focused-v2,focused-v3,full,repository}.log`.
Source was frozen during checks and committed afterward. Later edits are documentation only.

## Native identity and fixtures

Tested app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Debug 3.0.0 (738), arm64, macOS 27.0. `build/qa-xmp-baseline-cycle14/tested-binary-identity.json`
records source and executable hashes; debug dylib SHA-256 is
`f1a65115a50a44e872ae10c870d851620ae2c380aad571170aa9a0ed59e9138e`.

`build/qa-xmp-baseline-cycle14/photos` contains generated cycle12 PNG copies, manually authored
ACR elliptical-mask XMP, exposure 0.25, opaque XMP/JSON, unrelated pending captions and unknown
originals. B also embeds that technical XMP so explicit Reset uses embedded-plus-sidecar writing.
`fixture-origin.json` and `before-snapshot.json` record initial bytes. No user photos or preference
changes were involved. CUA operated the actual native app; no shell UI automation was used.

## Observed native behavior

1. **Old binary failure:** on verified `9c344fb`, A's Develop layer list displayed `QA ellipse`.
   Reset exposure with no external change failed: `The XMP sidecar changed before metadata could
   be saved: a-masked.xmp`. Dismissed and quit normally. Baseline failure snapshot exactly equals
   initial artifacts; this is failing baseline evidence, not a passing shutdown result.
2. **Corrected repeated save:** on `a777dd7`, the identical reset succeeded, persisting zero
   exposure and preserving A's mask, caption and opaque data. Undo changed the preview to 0.25
   but did not by itself persist it; an early inspection expecting persisted Undo was therefore
   not a passing save check. Then a direct exposure-slider click persisted +1.51 without a
   stale-XMP failure. This second actual save verifies own-receipt advancement.
3. **Genuine external conflict:** after that load/save, changed only disposable A XMP exposure
   from +1.51 to +1.75. Reset exposure failed visibly. The external XMP hash and every other
   artifact were preserved. Dismissed the error and pressed Command-Q; all app entries stopped
   with no second retry/discard decision. The unsaved requested reset had no durable carrier.
   This confirms the open lifecycle defect on the final implementation.
4. **Embedded reset:** relaunched deliberately and selected B. Explicit Reset develop adjustments
   completed without error, removing exposure/mask settings from both embedded XMP and its
   sidecar. Its unrelated caption and opaque records survived; pending became false. This was
   the explicit reset scope, not silent mask removal during an editorial operation.
5. **Fresh-load reconciliation:** selected A after reloading. Screenshot showed external +1.75
   and `QA ellipse`. Deliberately reset exposure again; the new operation succeeded at zero.
6. **Persistence:** after successful saves, quit normally, confirmed stopped state, relaunched
   the same binary and reopened both photos. A displayed its ellipse and Exposure 0.00; B showed
   only Global, Exposure 0.00 and no edited marker. Both lacked pending markers. A's unrelated
   caption appeared in the metadata editor. Quit normally again; all QA app entries are stopped.
   Complete artifact hashes/parsed states exactly match before and after this final relaunch.

Evidence: `baseline-failure-snapshot.json`, `repeated-save-snapshot.json`, `external-xmp-sha256.txt`,
`external-refusal-snapshot.json`, `reset-snapshot.json`, `completed-snapshot.json`,
`relaunch-snapshot.json`. Both PNG pixel payload hashes remain unchanged. A's entire source bytes
remain unchanged; B's source metadata changes only through requested reset. Captions, opaque XMP
and opaque JSON survive; history stays at three entries because these are technical operations.
Explicit completed writes establish their normal written-image snapshots.

## Remaining gates

Fix failed Develop-save retention across Quit, workspace exit and selection before claiming
safe failure recovery. Audit undo/redo persistence boundaries separately; the observed preview
Undo alone is not evidence of durable persistence. Native History Only, Restore/history,
Caption-to-Develop technical races, genuine RAW/C2PA, IME/VoiceOver and wider workflows still need
their own evidence; automated coverage does not substitute for those interactions.

Checklist A20 specifies the broader masked-XMP matrix. There are 35 unique complete cases
(20 agent, six final-user, nine external), all initially unrun and unassigned to a final candidate.
Source paths and JavaScript syntax pass static validation; interactive HTML validation remains
pending after the earlier local-URL policy rejection. No authoritative checkbox changed.
Heartbeat stays active with substantive progress and no readiness notification.

Final independent evidence audit PASS: initial/baseline-failure equality, final/relaunch equality,
all final physical hashes, external refusal preservation, and 35 complete checklist cases agree.
The genuine failure-lifetime blocker remains explicit; A20 now exercises dismissed-error exit paths.

## Next-cycle root cause map

App termination already calls `DevelopVersionFlushCoordinator` in `Aagedal_Photo_AgentApp.swift`
around line 493, but registered `EditWorkspaceView.flushActiveDevelopVersion` only flushes the
named-version session. `DevelopVersionSessionCoordinator.flushActive` returns success for Primary
(no active version/repository). Failed Primary state is only presentation/task state inside
`DevelopPersistenceSessionCoordinator`: finish removes the task, dismiss clears the failure, and
image/workspace transitions clear the session. A retained immutable Primary intent/result owner
must participate in shared flush before named-version handling. It must survive alert dismissal,
in-flight completion and view/image changes, keep exact original evidence, and provide safe
permanent-conflict recovery; blindly retrying against newly read XMP would adopt external changes.
