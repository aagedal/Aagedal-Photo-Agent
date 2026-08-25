# One-shot migration recovery validation

**Validated:** 2026-08-25  
**Scope:** audit plan 0.2 — Known People embedding versions and legacy keyword-list bookmarks

## Implementation evidence

- The Known People embedding migration copies the complete store, recursively reads the source and backup,
  and requires identical relative paths and bytes before reset begins.
- Backup, verification, or reset failure returns without advancing `knownPeople.embeddingVersion`. The prior
  store remains usable for the injected pre-reset failures covered here.
- The test host has a process-wide temporary Known People fallback. A focused test that removes its explicit
  storage override can no longer resolve the user's local or iCloud store.
- Keyword-list migration records stable completion IDs for every approved, structured, and quick list.
  A failed bookmark resolution, parse, write, or read-back verification leaves only that list pending and
  prevents the global migration marker from advancing.
- Successfully imported lists are read back before their completion ID is stored. Their source bookmark
  bytes remain available as recovery evidence, and a later retry does not overwrite the completed output.

## Automated validation

The following focused command succeeded on macOS:

```sh
xcodebuild test -scheme 'Aagedal Photo Agent Tests' -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/KnownPeopleServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/KeywordListLegacyMigrationTests' \
  -only-testing:'Aagedal Photo Agent Tests/FullScreenShortcutTests'
```

The run covered 15 logical tests across three suites. Focused migration coverage proves that:

- a deliberately incomplete backup is rejected before source reset and version stamping;
- an injected reset failure leaves the source record usable and the old version marker retryable;
- a failed legacy quick-list source remains pending while a verified approved list stays complete;
- retry imports only the recovered list, advances the global marker, and retains both source bookmarks; and
- teardown/reload remains confined to the test-process fallback.

The same run revalidated the related full-screen accessibility source regression. It does not replace the
repository's full unfiltered release test gate.

## Incident and recovery boundary

The first focused run exposed a teardown-order defect that briefly resolved the live iCloud Known People
root while an injected old embedding version was active. The production transaction created and verified a
complete pre-reset backup before clearing that low-use database. The user elected not to restore it; the
backup remains intact. The test-process fallback above was added before the successful rerun.

This validation closes the first four checklist substeps in audit-plan section 0.2. The separate
plain-language recovery notice and the broader disk-full, permission, corrupt-input, and iCloud-placeholder
exit matrix remain open.
