# Sports 2.1 follow-up validation — 2026-08-25

Scope: the four code-completable items that remained in `sports-2.1-plan.md`. Real-photo threshold
calibration was explicitly excluded and remains open.

## Implemented and checked

- Team-sheet/startlist Paste and File import use one deterministic parser. It accepts number/name
  rows separated by spaces, commas, or tabs, ignores headers/malformed rows, merges by number, and
  preserves an existing Known-People link on a name refresh.
- Known-People identity is persisted on face groups. A Sports context-menu action explicitly
  remembers a roster player for future matches, updates the reusable team and the active folder's
  embedded roster snapshot, and later folders can recover the player's number by `knownPersonID`.
- Referee/non-player exclusion is optional and migration-safe. Excluded groups remain editable but
  do not corroborate claims or write Person Shown; attached number claims become rejected.
- `(number)` and `{number}` expand during both single-image and batch variable processing. Only
  confirmed number claims, manual group assignments, and roster-backed identified faces contribute;
  suggested OCR values do not. Multiple values are deduplicated and sorted.

## Automated validation

Command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/aagedal-sports-followup-derived \
  -only-testing:'Aagedal Photo Agent Tests/SportsTaggingTests' \
  -only-testing:'Aagedal Photo Agent Tests/PresetVariableInterpolatorTests'
```

Result: **passed — 44 tests in 2 suites, with 0 failures**.

Two additional focused assertions were then added for `(number)` detection and exclusion from
number-claim corroboration. An incremental rerun compiled the app and both modified test sources
cleanly, but its test worker could not materialize while the shared UI suite was active. The
contending rerun was stopped cleanly and no process retained the derived-data test database or log
directory. The executed 44-test pass remains the validation baseline for this follow-up.
