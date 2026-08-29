# Plan status follow-up validation — 2026-08-29

## Implemented continuation

The next bounded Phase 4.1 command-router slice moved six user-initiated operations, represented by seven
typed cases, from the process-wide notification bus to the scene-owned `AppCommandRouter`:

- Import Photos;
- Back Up Edited Files;
- Open in Internal Editor and Open in External Editor;
- Move to Trash; and
- Move Rejected to Folder.

The application menu retains the existing saved-preference decision between the internal and external
editor. Content, browser, and safety handlers retain their previous behavior while receiving commands only
from their owning scene. Folder-row backup commands preserve their exact URL as a typed payload. Seven
obsolete notification declarations, menu/folder-row posts, and subscriptions were removed.

## Validation

Characterization coverage was authored before the production command cases and includes the folder URL
payload contract. After implementation, a fresh arm64 build compiled the complete application and test
targets, and `AppCommandRouterTests` passed all **8 tests in 1 suite** with `** TEST SUCCEEDED **`. The result
bundle is:

```text
/private/tmp/aagedal-command-router-followup-20260829/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-20-05-+0200.xcresult
```

This is incremental progress toward the broad command-router checklist item. Template, upload, metadata,
scope, Develop-layer, and other application-command notifications remain, so that item stays open.

## Import scan responsiveness follow-up

Primary and second-source discovery now publish immutable progress snapshots every five seconds while the
serialized filesystem actor continues scanning off the main actor. The Import window immediately presents a
bordered progress status with an indeterminate spinner plus live regular-file and supported-image counts;
second sources also show their WAV count. Once second-source enumeration finishes, the status explicitly
changes to voice-memo match analysis instead of continuing to claim that files are being scanned.

Characterization covers the five-second production cadence and exact file/image/WAV counts. The combined
`ImportSourceDiscoveryServiceTests` and `ImportViewModelTests` run passed all **17 tests in 2 suites** with
`** TEST SUCCEEDED **`. The result bundle is:

```text
/private/tmp/aagedal-command-router-followup-20260829/Logs/Test/
Test-Aagedal Photo Agent Tests-2026.08.29_15-28-35-+0200.xcresult
```
