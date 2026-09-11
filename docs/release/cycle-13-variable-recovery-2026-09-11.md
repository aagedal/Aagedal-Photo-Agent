# Cycle 13: scoped variable conflict recovery

Source `9c344fb7b0ef73026ee242165d86e76b1d4d1e19` passes independent review,
61 focused tests / six suites (1.705s), 2,654 integrated tests / 293 suites (98.963s),
repository validation and whitespace checks. Native permanent conflict, cancellation,
verified export, tamper rejection, scoped discard, remaining-photo retry and relaunch pass.
The app is still IMPLEMENTING: wider native cases and the 60 open plan criteria remain.

## Implementation and review

Starting from clean `6fac926` / verified implementation `fbe253f`, the core agent added
immutable complete recovery snapshots, private off-main export and exact-byte/receipt
verification. The caller agent replaced opaque retained admissions with exportable captured
inputs and added settled review ownership, exact-photo removal and guarded editor cleanup.
The coordinator added the review sheet, toolbar, native buffer barrier, test registration
and integrated validation. An independent agent reviewed source and corrections.

Exports include original/captured/resolved metadata, technical fields, complete pretrim
history, known/null original state, original policies, first physical/JSON evidence and
partial or uncertain write receipts. Export and discard protect photos, matching XMP,
metadata folders, symlinks and hardlinks. Review holds ownership across awaits. Only verified
exported request IDs can be removed; saved files and other photos remain untouched.

Review found and corrected sheet remount/disappearance lifetimes and a shared-template
resurrection path: discarding A while B remains retained must preserve cleanup ownership
until B resolves. Direct saves, Caption capture and new variable/template admission now
refuse the unchanged discarded buffer; Retry can finish deferred cleanup even with no
requests left. Active composition, missing native buffer barriers and in-flight saves
cannot silently destroy or re-enqueue the old buffer. Newer editor values survive.

## Automated validation and failed attempts

Commands used the Debug `Aagedal Photo Agent Tests` scheme, macOS destination and serial
execution. Focused selection: VariableConflictRecoveryTests, VariableConflictRecoveryCallerTests,
VariableMetadataWriteServiceTests, VariableMetadataCallerTests, VariableDraftLifecycleIntegrationTests,
and CaptionConflictRecoveryTests. Integrated run used the same command without filters.
`scripts/ci/validate_repository.sh`, project plist validation and `git diff --check` pass.

- First focused attempt exited 74 before compiling: sandbox denied Swift/Clang/SwiftPM cache
  writes. The authorized build-cache permission path resolved this execution restriction.
- Focused v2 compiled but exited 65. Logical `/var` fixture aliases correctly failed protected
  export validation; caller fixtures now use physical `/private/tmp`. A review-freeze assertion
  incorrectly invoked an already-running Retry early return; it now tests actual new admission.
- v2 also exposed a product stack overflow in JSONEncoder when encoding the large nested
  recovery value. Diagnostic reports `Aagedal Photo Agent-2026-09-11-195122.ips` and subsequent
  launches identify thread stack exhaustion at recovery document encoding. Immutable final
  Sendable reference wrappers now avoid multiplied inline record copies while preserving every
  Codable field. No payload/assertion was removed and no stack-size workaround was used.
- Focused v3 and integrated run pass on the final frozen source, with no host crash.

Logs: `/private/tmp/aagedal-coordinator-cycle13-{focused,focused-v2,focused-v3,full,repository}.log`.
The application build was committed after all final checks; subsequent edits are documentation only.

## Native identity and fixtures

Tested Debug app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_Photo_Agent-hlgfpmukfpendwestygmmhxmllgk/Build/Products/Debug/Aagedal Photo Agent.app`.
Version 3.0.0 (738), arm64, macOS 27.0. Identity and executable/dylib hashes are in
`build/qa-variable-recovery-cycle13/tested-binary-identity.json` (debug dylib SHA-256
`0225777ccbcd3c491af5381cd50c03f138b165770a2920f4b436ce31d2798edd`).

`build/qa-variable-recovery-cycle13/photos` contains two generated PNG copies from cycle12,
owned JSON, known/null originals, unrelated captions and opaque fields. No user photos were
used. A's pending orientation forces physical refusal after variable JSON preparation.
B's empty XMP directory forces pre-prepare input failure. `fixture-origin.json` and
`before-snapshot.json` record origin and initial bytes. No app preference was changed.

## Observed computer-use results

1. Opened the fixture folder with no photo selected and ran Process Variables in Folder.
   The full error sheet reported 0/2, A's retained rotation/resolved pending draft and B's
   invalid XMP input. A history advanced 3→4; B remained unprepared.
2. Changed only disposable A JSON credit to `External newer credit C13` and added an opaque
   witness. Retry reported A ownership/content conflict and B input failure. Newer A bytes
   remained unchanged.
3. Review Variable Conflicts listed both full photo paths. Selected A and cancelled review;
   reopened to confirm both remained. Cancelled the save panel; Discard remained disabled.
4. Exported `photos/recovery-a.json`. Native UI showed verified export and enabled Discard.
   Independent inspection confirmed mode 0600, exactly one entry, complete request evidence,
   original unknown flag, and the full variable delta. Appending one newline externally made
   Discard fail with a visible retained-work message and disabled it. Screenshot inspection
   confirmed readable instructions/error and accessible footer controls.
5. Exported `photos/recovery-a-verified.json` and discarded A. Reopening review listed only B.
   A's external JSON hash exactly matched its pre-discard witness. Removed only B's empty
   obstruction directory and retried. Retained-work controls disappeared; B completed physical
   persistence with resolved title and history 3→4, pending false. A stayed pending with its
   rotation, newer credit, unrelated caption and unchanged source PNG.
6. Quit normally, confirmed all QA app entries stopped, relaunched the same binary and reopened
   the folder. A showed a pending marker; B did not. Selected each: resolved titles and unrelated
   captions appeared in the live metadata editor. Quit normally again. Every fixture/export
   hash and parsed metadata state exactly matches the pre-relaunch snapshot. All QA app entries
   are stopped; no preference restoration or fixture obstruction remains outstanding.

Evidence under the fixture root: `prepared-snapshot.json`, `external-a-sha256.txt`,
`verified-export-original.json`, `completed-snapshot.json`, `relaunch-snapshot.json` and exports.
The inspection helper independently verifies source pixel payloads, known/null originals,
history and pending states. Both source pixel hashes remain unchanged; A's entire source bytes
remain unchanged. The intentionally tampered export remains as a failure fixture.

## Remaining work

This validates the bounded unselected-folder recovery path. Focused native buffers, >20-field
native templates, shared-template/IME interaction, in-flight disappearance, authentic RAW/C2PA,
VoiceOver, performance and other workspaces still require their own native evidence. Automated
cases cover several of those ownership edges but do not substitute for interaction testing.

Next implementation priority is the three legacy single-photo/Develop callers comparing newly
parsed XMP mask IDs; preserve exact load-time bytes and verified receipt updates. Voice archive,
reassociation, transcription/delivery and hardware/external/legal gates remain as listed in readiness.
No authoritative checkbox changed (9 audit / 23 investigation / 22 journalistic / 6 solar open).
HTML checklist has 34 complete cases (19 agent, six final-user, nine external), all initially
unrun and unassigned to a final candidate. Static checks pass; interactive HTML validation remains
pending after the earlier local-URL policy rejection. Heartbeat remains active; no readiness
notification is due.

Final independent evidence audit PASS: snapshot equality, A external witness/source bytes, both pixel/original records, export permissions/content, source identity and stated remaining scope agree. Final HTML static validation confirms 34 unique complete cases and resolving source paths; extracted JavaScript passes syntax checking.
