# Batch rename recipe foundation validation

**Validated:** 2026-08-21  
**Plan:** Journalistic metadata workflow, Phase 3

## Implemented contract

- `BatchRenameRecipe` is a versioned Codable value with no UI or filesystem dependency.
- Components support literal text; original full name, stem, and extension; configurable
  sequences; capture/creation/modification dates; typed metadata, camera, rating, and label values;
  and workflow job/import titles.
- Capture dates have an explicit missing/fallback policy, while date formatting uses the POSIX
  locale, Gregorian calendar, and a persisted IANA timezone for deterministic previews.
- Evaluation order is fixed: components, declared substitutions, case conversion, whitespace,
  filesystem sanitation, then Unicode normalization.
- Missing token values explicitly produce empty, fallback, preserve-original, skip, or block
  outcomes. Invalid regular expressions block evaluation with their stage and pattern.
- Filename sanitation covers path separators, control and cross-platform reserved characters,
  hidden/trailing-dot handling, safe replacements, and empty-name fallback.

## Test evidence

The focused suite covers each token group, positive and negative padded sequences, deterministic
dates, every missing-value policy, substitution ordering and invalid regexes, transform ordering,
filesystem edge cases, locale-independent case conversion, Unicode composition, Codable round
trips, and rejection of newer schemas.

Command:

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-batch-rename-derived' \
  -only-testing:'Agedal Photo Agent Tests/BatchRenameRecipeTests'
```

Result: **11 tests passed** and the production target built successfully.

## Remaining integration

- Persist and manage user recipes through the preview sheet.
- Build immutable rename plans with collision and associated-artifact checks.
- Write original filenames to the selected XMP property when configured.
- Execute confirmed plans transactionally with cycle handling and rollback reporting.
