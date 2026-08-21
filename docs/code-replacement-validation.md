# Code replacement validation

**Validated:** 2026-08-21  
**Scope:** Phase 2 Photo Mechanic-compatible list parser, configuration, preview, and safe pure engine

## Implemented contract

- `CodeReplacementConfiguration` is versioned, `Codable`, `Equatable`, and `Sendable`, with an
  explicit enable state and start/end delimiters.
- Persisted source references contain a stable identifier, display name, last-known path,
  fingerprint, and opaque bookmark identifier/metadata. They never contain bookmark bytes, list
  contents, credentials, or replacement values.
- The parser accepts strict UTF-8 `code<TAB>replacement` rows, UTF-8 BOM, and CRLF/LF/CR line
  endings. Blank lines are ignored; malformed rows and empty columns remain visible as diagnostics
  while independent valid rows remain usable.
- Exact matching is case-sensitive and deterministic. Unknown text is preserved, doubled
  delimiters produce literal delimiters, and adjacent exact tokens work when the delimiters are
  identical.
- Same-value duplicate definitions warn. Conflicting duplicates are quarantined and preserved in
  the preview with both source-line and occurrence diagnostics; they are never expanded silently.
- Codes containing a configured delimiter are preserved atomically and reported instead of
  allowing a valid suffix code to expand.
- An active IME composition state refuses the complete replacement operation. Invalid UTF-8 and
  invalid delimiter configuration also leave the source text untouched.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-code-replacement-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/CodeReplacementTests'
```

Result: **13 tests passed**, and the full application/test dependency graph compiled successfully.
The project file also passes `plutil` validation and `git diff --check` is clean.

## Integration and remaining extensions

Security-scoped source selection, settings, real marked-text detection, and explicit atomic Caption
Workspace preview/apply are now complete; see
[the Caption Workspace integration record](caption-code-replacement-validation.md).

- Add broader list-management/import UI if newsroom workflows require comments, quoting,
  multiline values, or embedded tabs; those forms are intentionally outside the interoperable
  two-column subset.
