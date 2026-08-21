# Deadline Send composition validation — 2026-08-21

Deadline Workspace now owns the complete confirmed-send boundary. It retains the exact preflight
request, publication, revision token, Develop snapshots, and off-main SHA-256 source revisions.
Send remains disabled while evaluation is active, when blockers or missing source evidence exist,
when the publication is stale, when a non-staged write strategy is selected, or while another batch
is active/recoverable. Warning identifiers require explicit batch-scoped acceptance and are reset
when the input changes.

Before confirmation, Caption and Develop editors are flushed and the composition revalidates the
live request/token/profile/selection, pending metadata, exact resolved metadata, Camera Raw state,
and a fresh source-byte revision. The frozen confirmation enumerates every output filename and its
format, gamut, quality, resolution, destination UUID/path, staged-copy policy, and C2PA consequence.
No staging or network operation starts until that confirmation is accepted.

Production execution uses the private workflow registry, production staging/preservation factory,
credential-contained FTP/FTPS/SFTP transport, workflow coordinator, and receipt repository. The UI
projects exact lifecycle progress and cancellation; cancellation during staging is persisted at the
next safe boundary rather than being lost. A sent batch reloads receipt Activity. Relaunch validates
the full registry resume record: exactly one eligible workflow may be recovered automatically,
while multiple candidates fail closed instead of being guessed.

Validation used isolated DerivedData at `/private/tmp/aagedal-deadline-send-build-01`. A full
`build-for-testing` succeeded, followed by 63 focused tests across six suites with no failures:
Deadline coordinator/model, live snapshot, planning, profile, workflow coordinator, and registry.
Coverage includes same-token source-byte changes, missing source hashes, warning reset,
confirmation projection, source/metadata/Develop drift, production registry locations,
failure/relaunch/receipt de-duplication, and staging/upload cancellation. `git diff --check`, a
targeted conflict/whitespace scan, and project-file `plutil -lint` passed.

Automatic recovery intentionally refuses multiple retained workflows. Explicit workflow selection
and confirmed manual cleanup are owned by the Activity workflow surface; verified staging is never
deleted automatically by this composition.
