# Cycle 17 — Known People first-time identity

**State:** COMPLETE for the first-time identity slice. Untracked local stores can now acquire
durable interchange identity. Cycle 18 subsequently completed the high-level import/export
services and UI; explicit local-to-cloud reconciliation remains.

## Source and environment

- Source base: `b6fa8d0` on `main`; the validated identity slice was committed as `85c7080`.
- Host: Apple Silicon (`arm64`), macOS 27.0 build 26A428.
- Scheme/destination: `Aagedal Photo Agent Tests`, Debug, `platform=macOS`,
  parallel testing disabled for coordinator runs.
- No native UI result or app candidate was claimed for this service-only slice. Cycle 18 records
  the later native UI evidence.

## Implemented transaction

`KnownPeopleLocalIdentityAssignment.prepare` performs a read-only capture of an untracked
populated or empty local root. It generates the library and installation UUIDs once and stores
them in an immutable plan. The plan binds the builder's complete directory/path/byte digest and
root device/inode to identical inventory evidence before capture, after capture and in the
managed replacement plan. A file changed for capture and restored before the next sample is
therefore rejected rather than allowing an older snapshot to overwrite newer local data.

Preparation refuses an existing or malformed identity state, an orphaned admitted-package
cache, tombstones, legacy `database.json`, links, hardlinks, invalid JPEG, unknown embedding
provenance, iCloud sync and active routing. It writes nothing.

Commit accepts only the untracked replacement decision and runs through
`KnownPeopleService.replaceManagedStore`, retaining route ownership, the process-wide import
lane, whole-root reservation, atomic swap and recovery truth from cycle 16. The planned initial
installation ID must be nonzero and cannot override existing state. Precommit failure or
cancellation may retry the same immutable plan and IDs. A per-plan process receipt admits one
executor at a time and permanently returns an already committed result, including postcommit
readback, durability or cancellation uncertainty, without replaying the swap.

After successful assignment, strict local capture reuses the exact admitted package bytes and
the displaced original root remains available at the reported recovery path.

## Verification

- Coordinator-focused identity, builder and managed replacement run: 46 declared tests /
  84 expanded cases across three suites; pass in 10.334 seconds.
  Log: `/private/tmp/aagedal-people-identity-coordinator-v1.log`.
  Result: `/private/tmp/aagedal-people-identity-coordinator-v1.xcresult`.
- Complete suite after the final identity source: 2,791 tests / 305 suites; pass in
  114.329 seconds. Log: `/private/tmp/aagedal-full-known-people-identity-v1.log`.
  Result: `/private/tmp/aagedal-full-known-people-identity-v1.xcresult`.
- Independent source/test audit: approved. It verified complete inventory binding, ABA
  rejection, stable retry IDs, same-plan concurrency, owner-only production commit, empty and
  populated stores, malformed/legacy/iCloud refusal and unchanged recovery propagation.
- Project plist validation and `git diff --check` pass before repository validation.

## Follow-up status

Cycle 18 adds unified strict directory/archive admission, high-level export preparation, one
shared MainActor controller in Settings and Expanded Known People, clearly separate schema-1
legacy commands, and disposable-root native import/export, confirmation, cancellation and
recovery checks. The ZIP32 65,534-entry limit is enforced and presented in Photo Agent; companion
coordination remains required.

Explicit local-to-cloud reconciliation before enabling iCloud for a replaced or newly assigned
library remains open, along with broader accessibility, relaunch and release-candidate gates.

Overall 3.0 readiness remains **IMPLEMENTING**. No final manual-testing notification is due.
