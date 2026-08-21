# Deadline profile validation

**Validated:** 2026-08-21  
**Scope:** Phase 4 portable profile model, references/snapshots, diagnostics, and JSON boundary

## Implemented contract

- `DeadlineProfile` is versioned, `Codable`, `Equatable`, and `Sendable`.
- Validation, metadata template, rename recipe, and export configuration can be represented by a
  stable library reference or a portable typed snapshot.
- The profile stores ordered/visible caption field IDs, required-list references, template
  variable policy, rename collision policy, destination connection ID and remote path template,
  GPS policy, and originals/XMP/staged-copy metadata strategy.
- Only a stable connection identifier is serialized. Existing FTP/SFTP passwords remain in the
  app's Keychain-backed connection store; credential-bearing identifiers fail validation.
- Missing validation profiles, templates, lists, rename recipes, export configurations, and
  connections produce deterministic diagnostics against an injected catalog.
- JSON import/export is pretty and stable, enforces a bounded file size, migrates the initial
  unversioned shape with safe defaults, rejects unsupported newer schemas, and will not overwrite a
  destination written by a newer app.
- Template snapshot conversion throws on an unknown field key instead of silently dropping it;
  duplicate caption/list/template field identities are rejected.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-deadline-profile-tests-01' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlineProfileTests'
```

Result: **7 tests passed**, and the full application and test targets compiled successfully.

## Remaining integration

- The profile repository, persisted selection, management/import/export UI, and initial live
  preflight projection are complete; see
  [the saved-profile validation record](deadline-profile-repository-validation.md).
- Resolve the remaining references against stable validation/list/recipe/export stores and expose
  a complete profile field editor.
- Feed captured permission, rename, render, staging, and reachability facts into preflight and the
  future staged delivery coordinator.
- Add richer assignment packages for embedded roster/vocabulary files without changing this
  delivery-profile schema.
