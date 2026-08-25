# Backup, restore, and crash-interruption validation — 2026-08-25

**Scope:** Phase 12 partial automated evidence for investigation case/version persistence and
Image Analysis Project import. This note does not close the broader release-candidate drill.

## Automated evidence

- A new `AnalysisCaseRepository` characterization test performs two durable saves, replaces the
  newest primary with a deliberately truncated schema-9 document, recreates the repository, and
  verifies that exact source matching recovers the previous case from the bounded backup. Loading
  is non-destructive: both the interrupted primary bytes and the known-good backup bytes remain
  unchanged for diagnosis and explicit repair.
- Existing `DevelopVersionCatalogTests.repositoryRoundTripAndBackupRecovery` already performs the
  equivalent domain-level corrupt-primary recovery check for a source-bound named-version catalog,
  including the `.backup` source signal and absence of XMP writes. Existing promotion tests inject
  failure at every durable promotion step and verify that the Primary recovery version is retained
  once its catalog write succeeds.
- A new Image Analysis Project import seam injects failure after complete archive validation,
  payload staging, and analysis-case rebasing but before the final install. The test proves an
  existing empty destination is preserved and the temporary import is cleaned on an ordinary
  thrown failure. A subsequent un-injected retry proves the validated staging directory replaces
  that empty destination successfully.
- The project-import commit now uses one `FileManager.replaceItemAt` operation when a save panel has
  already created the empty destination. Previously it removed the destination and then moved the
  staging directory, leaving a process-interruption window in which the requested destination was
  absent.
- Report generation remains snapshot-based and cancellable before its final
  `Data.write(options: .atomic)` call. Existing renderer and PDF structural tests cover generated
  bytes, but this follow-up did not simulate killing the app or exhausting storage during the final
  report write.

Focused command:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/aagedal-recovery-drills \
  -only-testing:'Aagedal Photo Agent Tests/AnalysisCaseTests/recoversExactCaseFromBackup()' \
  -only-testing:'Aagedal Photo Agent Tests/ImageAnalysisProjectArchiveTests/interruptedImportPreservesEmptyDestination()'
```

Result: **passed** on 2026-08-25. Swift Testing executed 2 tests in 2 suites with 0 failures.

## Hands-on drills still required

The Phase 12 checklist remains open until a release-candidate build has documented operator-visible
results for all of the following:

1. force-quit or terminate the process during case/catalog replacement, report export, project
   export, and project import, then relaunch and verify the user-visible recovery state;
2. repeat the boundaries with disk-full, permission loss, unplugged external storage, and relevant
   iCloud placeholder/offline transitions;
3. restore a real working folder plus its Application Support fallbacks from backup and verify
   source identity, case selection, named versions, report regeneration, and project import;
4. inspect and deliberately resolve any retained `.backup`, `.partial`, `.importing`, or corrupt
   artifacts, confirming that unrelated user files are never removed;
5. repeat upgrade, downgrade, and newer-schema recovery using signed release-candidate builds.

The automated tests characterize two high-value boundaries and remove one real crash window, but
they are not substitutes for process death, device removal, storage exhaustion, or operator restore
exercises.
