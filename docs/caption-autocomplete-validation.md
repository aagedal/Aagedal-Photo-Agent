# Caption autocomplete validation

**Validated:** 2026-08-21  
**Scope:** Phase 2 field-aware, explicit Caption Workspace suggestions

## Implemented contract

- A pure deterministic service filters candidates only for the requested `MetadataFieldID`, ranks
  prefix before substring matches, retains typed source provenance, merges duplicates, and limits
  results without mutating metadata.
- Caption Workspace aggregates approved lists, structured keyword/person vocabularies, Known
  People names, metadata already loaded for the current folder, and existing UTF-8 quick lists.
- The Option-Space command and toolbar action are available only for an exact eligible FocusState
  field. Opening captures that field before the compact keyboard-accessible popover takes focus, so
  a suggestion cannot drift into a neighboring editor.
- Suggestions are inert until explicitly selected. Scalar fields replace their value; repeatable
  fields append canonical expansion values in source order with Unicode/case-normalized
  deduplication.
- Known People and structured-person candidates carry display provenance only. Inserting one edits
  metadata text and never confirms or changes face, group, roster, or Known Person identity.
- Actual AppKit marked-text state is checked before opening and again before insertion. Active IME
  composition refuses the operation atomically.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-caption-autocomplete-tests-01' \
  -jobs 2 \
  -only-testing:'Aagedal Photo Agent Tests/CaptionAutocompleteServiceTests'
```

Result: **12 tests passed** and the app/test target graph compiled successfully. Explicit PBX test
membership, PBX parsing, and `git diff --check` also passed.

## Remaining integration

- Current-folder candidates intentionally use metadata already loaded in `BrowserViewModel`; they
  do not trigger a separate disk crawl.
- Add UI-level focus/VoiceOver tests and a manual keyboard/IME pass with the real AppKit editors.
- Persons-left-to-right confirmation and configurable shortcut presets remain separate work.
