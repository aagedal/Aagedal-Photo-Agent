# 3.0 autonomous release coordinator

Requested 2026-09-09. This task coordinates implementation and verification through a
recurring Codex heartbeat in the existing local task. The intended handoff is a tested
candidate and an HTML checklist for the user's final acceptance testing.

## Scope and authority

Read `docs/README.md`, `docs/app-improvement-audit-plan.md`,
`docs/v2.3/delivery-plan.md`, `docs/journalistic-metadata-workflow-plan.md`, and
`docs/suncalc-plan.md`. Follow their linked acceptance criteria and newest validation
records. The three portfolio initiatives target 3.0; the improvement audit is also in
scope. Historical `v2.3` paths do not mean those features are a separate release.

Complete implementation, bug fixes, meaningful tests, computer-use testing, documentation,
and local commits autonomously. Make routine engineering decisions and document them.
Use sub-agents for independent implementation, review, or test preparation when useful;
the coordinator owns integration and readiness. Do not turn conditional AI-origin or
localization work into mandatory features without the product decisions required by
their plans. Do not silently defer mandatory work to achieve a green checklist.

This authorization ends at final user acceptance. Publishing a release, sending files
to production recipients, changing remote branch protection, making purchases, and
signing legal attestations need their own authorization. Prepare concrete artifacts and
finish independent work before requesting such actions. Use disposable local fixtures
and test destinations; preserve user photos, credentials, and existing app data.

## Each working cycle

1. Read this protocol and `readiness.md`, inspect Git status and recent commits, then
   reconcile changed plan items with source and evidence. Check for other active tasks
   editing this checkout. Do not overwrite, revert, or commit unrelated user work.
   Coordinate concurrent work or use an isolated checkout when necessary.
2. Select the highest-impact unfinished release work. Prefer closing complete acceptance
   criteria over endless incidental refactoring. Break broad items into concrete tasks
   with expected behavior, files/owner, and a verification method. Keep the ordered next
   actions and unresolved defects in `readiness.md`. Classify required qualified legal
   review and remote branch-protection enforcement as external dependencies early;
   local substitutes cannot satisfy them or silently move them to final user acceptance.
3. Delegate bounded, non-overlapping slices to available sub-agents. Give each clear file
   ownership and acceptance criteria. Reserve one owner for the GUI and one coordinator
   for integration/builds/commits; sub-agents sharing a checkout must not race those actions.
   Ask an independent reviewer to inspect risky changes and the final candidate.
4. Implement, inspect the diff, and run appropriate focused checks. Fix failures before
   broadening validation. Run the full suite and repository validation after integrated
   application changes and at the final candidate gate. Do not repeat full checks on
   unchanged source merely because a heartbeat fired.
5. Exercise implemented user workflows in the actual built macOS app with available
   computer-use tools. Recheck old environment-availability notes instead of treating
   them as permanent blockers. Capture observed outcomes, failures, and useful evidence.
   Fix reproducible defects, then rerun affected paths. Static review and unit tests do
   not count as manual interaction evidence.
6. Commit coherent reviewed changes when reasonable, staging only owned files. Keep
   implementation status and verification status separate. Update authoritative plans
   only when their exact criteria are satisfied, and link dated evidence. Do not push or
   publish as part of this workflow.
7. Save a compact handoff in `readiness.md`: exact revisions, completed work, validation
   outcomes/evidence paths, defects, blockers with attempted remedies, and next actions.
   Continue useful work within the run; the heartbeat resumes it after the run ends.

## Verification evidence

Use a durable dated report under `docs/release/` for each material verification cycle.
Record the tested commit and dirty-source state, app path/version/build, macOS and
hardware, fixture origin, exact command or UI steps, expected and observed behavior,
result, and relative evidence paths. Keep large artifacts in an ignored build directory
and identify them with hashes where useful. Do not put private photos or secrets in Git.
Preserve concise results in the repository even if temporary logs later disappear.

Known repository commands (recheck the current project before running):

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO
scripts/ci/validate_repository.sh
git diff --check
python3 -B scripts/ci/build_model_free_candidate.py build/model-free-candidate-UNIQUE-RUN-ID
```

The candidate builder requires clean committed source and a fresh output directory.
An unsigned candidate is evidence of build/package consistency, not notarization,
production model availability, or launch success. Launch and inspect the candidate
actually offered to the user. Required permissions must use the existing approval
mechanism; never bypass an unavailable tool, sandbox, or accessibility permission.

Computer-use coverage must include the applicable Browser/import, Caption/metadata,
Batch Rename, voice memo, Develop/versions/Compare, Analysis/markup/reports, map/solar,
Deadline/preflight/export, Known People/storage/recovery, and accessibility workflows.
Use the HTML checklist and authoritative plans to derive exact cases. Verify persistence
after relaunch and representative failure/cancellation paths, not just happy paths.
Only one agent may operate the desktop at a time. Restore changed test preferences and
leave a clear record of fixture locations. Do not interrupt unrelated user applications.

## Readiness gate and stopping rules

`readiness.md` uses IMPLEMENTING, VERIFYING, BLOCKED, or READY_FOR_USER_TESTING.

READY_FOR_USER_TESTING requires all of the following:

- All unconditional 3.0 feature and implementation criteria are complete, with a
  traceable disposition for every open plan item. Existing explicitly conditional or
  post-acceptance distribution steps remain visibly separate, never falsely checked.
- No known unresolved release-blocking defect, including data loss, incorrect evidence,
  broken primary workflows, or required accessibility failures.
- Relevant automated checks, a complete integrated suite, repository checks, and package
  verification pass for the candidate source. Any later source change invalidates
  affected evidence and requires appropriate revalidation.
- Required agent-executable UI, persistence, failure, recovery, and performance cases
  have observed passing evidence. Required external/hardware cases have evidence too,
  unless the authoritative plan explicitly assigns them to final user acceptance.
  Missing credentials or hardware are blockers, not passing results.
- An independent reviewer audits the diff, requirement coverage, test evidence, remaining
  risks, and candidate identity. The coordinator resolves findings and writes a reasoned
  readiness decision; a sub-agent's assertion alone does not pass this gate.
- `manual-testing-checklist.html` is current, labels the exact candidate commit/build/path,
  and contains clear setup, numbered actions, expected results, priorities, cleanup,
  pass/fail/blocked recording, and notes. Keep human results initially unrun. Explain any
  separately outstanding distribution/signing gates. Verify that the HTML opens and works.

On success, record READY_FOR_USER_TESTING and the candidate, pause this heartbeat through
the automation tool, and deliver the candidate, checklist, evidence summary, and remaining
human/distribution steps. Further source changes or user-reported failures reopen relevant
gates; resume work only in response to the user's continuation instruction or an active
schedule. Final user acceptance does not itself authorize publication.

When blocked, first finish all independent work and try safe alternatives. Record the
specific missing dependency and smallest user action. If blockers prevent all useful
progress across three consecutive runs, even if their labels differ, record BLOCKED,
pause the heartbeat through the automation tool, and issue a single actionable blocker handoff. Do not loop forever,
weaken requirements, or claim readiness. Rate limits and host availability are execution
constraints, not product failures; do not buy credits or redeem resets automatically.
Reset the no-progress counter only after substantive implementation or verification
progress; rewriting status notes or repeating an unchanged failed check does not count.

Update or pause the existing automation by its saved ID using the automation tool;
preserve its other fields and do not create duplicate schedules or edit scheduler files.
