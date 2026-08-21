# Caption code replacement integration validation

**Validated:** 2026-08-21  
**Scope:** Phase 2 security-scoped list settings and explicit Caption Workspace preview/apply

## Implemented contract

- `CodeReplacementSettingsStore` persists the versioned non-secret configuration separately from
  opaque security-scoped bookmark bytes. Bookmark access is balanced, stale bookmarks refresh, and
  file access is injectable for tests.
- Caption Workspace settings expose enable state, start/end delimiters, source choose/reload/remove,
  source identity/path, entry count, and every parser diagnostic.
- Code replacement is an explicit command, never a live typing side effect. It is limited to
  Headline, Description, and Extended Description; keyword, person, creator, identifier, location,
  rating, label, date, GPS, orientation, and Camera Raw state are untouched.
- Before flushing, the command queries the actual AppKit `NSTextView` marked-text state. Active IME
  composition refuses the operation, so marked text is never copied into the model or sidecar.
- A committed draft crosses the existing CaptionSession flush barrier, then produces an all-field
  before/after preview. Apply is atomic and available only for a changed, valid result.
- Invalid source/configuration, an occurring ambiguous code, or an occurring delimiter-containing
  code returns no mutable metadata. Unused conflicting definitions remain visible as source
  diagnostics without blocking independent safe replacements.
- A pending preview captures the standardized current image URL and exact full `IPTCMetadata`
  input. Apply revalidates both and refuses if navigation or any draft field changed meanwhile.
- The command does not change CaptionSession selection, current image, or editor focus.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-caption-code-integration-01' \
  -only-testing:'Aagedal Photo Agent Tests/CodeReplacementTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionCodeReplacementCoordinatorTests' \
  -only-testing:'Aagedal Photo Agent Tests/CaptionSessionTests'
```

Result: **31 tests passed in 3 suites**. The focused integration suite passes **9 tests**. The full
application/test dependency graph compiled, the project passes `plutil`, and `git diff --check` is
clean.

## Remaining extensions

- The supported interoperable source is intentionally strict two-column UTF-8. Comments, quoting,
  multiline values, and embedded tabs require a separately versioned format if added later.
- Matching remains case-sensitive with no Unicode normalization, following exact newsroom-code
  semantics.
- Replacement remains an explicit post-flush command; there is no implicit expansion while typing.
