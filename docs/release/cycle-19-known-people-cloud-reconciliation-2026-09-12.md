# Cycle 19 — Known People cloud reconciliation

**State:** COMPLETE for the explicit local-to-cloud replacement implementation and automated
verification. Overall 3.0 readiness remains **IMPLEMENTING** because native iCloud/multi-Mac,
cross-app and broader release gates remain. No final manual-testing notification is due.

## Source and scope

- Implementation commit: `05f484a` on `main`, based on cycle-18 commit `c87cc63`.
- This checkpoint closes the code-level gate that prevented a locally replaced or newly assigned
  Known People library from enabling iCloud sync.
- The existing preserve-newer route remains the ordinary sync path. A state explicitly marked as
  requiring reconciliation instead presents a separate destructive confirmation and publishes the
  complete local library as a new cloud generation.
- Automatic App Group sharing with FTP Sync is not part of this checkpoint.

## Publication and routing behavior

`KnownPeopleCloudGenerationPublisher` stages a complete strict managed projection under a
write-once UUID in `generations/`. It validates the staged projection and retained activation
package, marks that generation cloud-ready, and commits only `current-generation.json` to make it
active. A failure before the pointer write leaves the previous generation selected. Cancellation
arriving during the non-preemptible pointer write still performs uncancelled readback and returns
durable publication evidence instead of reporting a false precommit cancellation.

The pointer decoder rejects unknown keys, non-canonical or zero UUIDs, invalid hashes, unexpected
format/schema values, reused generation IDs and generation-directory symlink escapes. Resolution
binds the pointer to the strict retained activation package rather than requiring the live cloud
projection to remain byte-identical forever; normal post-activation person edits therefore remain
valid while damage to the authority package fails closed.

`KnownPeopleService.reconcileLocalManagedStoreToCloud` retains the existing process-wide route and
whole-root ownership. It strictly captures the local managed store, refreshes its authority through
the existing replacement transaction, publishes the new cloud generation, and only then clears the
matching local reconciliation gate. The preference, resolved service route and metadata watcher are
switched only after verified publication. A local-only generation cache gives synchronous service
access the last resolved route while the cloud pointer remains authoritative on refresh.

Settings distinguishes the destructive replacement from the ordinary privacy confirmation. The
alert states that the local library—including removals or an intentionally empty library—replaces
the active cloud generation and is not merged with old cloud records. Enabling all categories uses
the same explicit Known People branch without changing the other category workflows.

## Automated verification

- Final cloud-publication suite: 6 tests / one suite pass in 0.948 seconds.
  Log: `/private/tmp/aagedal-known-people-cloud-generation-focused-v7.log`.
- Routing plus cloud-publication checkpoint before the final cancellation case: 45 tests / two
  suites pass in 1.546 seconds, with the active-generation route covered directly.
  Log: `/private/tmp/aagedal-known-people-cloud-reconciliation-focused-v5.log`.
- Related managed-store, snapshot, service, routing and publication regression: 151 tests / five
  suites pass in 25.496 seconds.
  Log: `/private/tmp/aagedal-known-people-cloud-reconciliation-related.log`.
- Complete suite: 2,839 tests / 311 suites pass in 113.685 seconds.
  Log: `/private/tmp/aagedal-known-people-cloud-reconciliation-full.log`.
- Repository validation passes release metadata, 29 JSON documents, two property-list/privacy
  manifests, the Xcode project, bundled binary/model provenance, logger privacy, investigation
  privacy, conflict-marker and whitespace checks.
  Log: `/private/tmp/aagedal-known-people-cloud-reconciliation-repository-v2.log`.

The passing Xcode logs retain existing LMDB map-full diagnostics and known compiler/App Intents
warnings; no assertion failed. Independent source review was not performed in this checkpoint.

## Remaining evidence and work

1. Exercise the destructive confirmation, interruption boundaries, empty/removal-bearing
   publication, relaunch and a second Mac against a disposable real iCloud container.
2. Coordinate and test the 65,534-entry ZIP32 presentation limit in FTP Sync and complete the
   cross-app matching/re-export/restore matrix.
3. Resolve legacy embedding provenance and production AuraFace distribution trust before claiming
   compatible production recognition.
4. Keep automatic App Group publication as a later, separately consented phase after both signed
   targets share the entitlement.
