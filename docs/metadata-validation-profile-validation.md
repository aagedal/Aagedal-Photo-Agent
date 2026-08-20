# Metadata validation profile JSON validation

**Date:** 2026-08-20  
**Scope:** journalistic metadata workflow, Phase 1 validation foundation

## Implemented behavior

- A validation profile is a versioned, portable JSON object with a stable UUID, display name, and
  ordered rules.
- Every requirement uses an explicit `type` discriminator plus named values such as `field`,
  `count`, `expression`, `values`, and `whenPresent`. The file contract does not depend on Swift's
  synthesized associated-value enum representation.
- The short-lived synthesized version-one rule representation remains readable and is migrated to
  the explicit contract on the next export.
- Export validates the complete profile, emits pretty-printed sorted JSON with a final newline, and
  atomically replaces the chosen destination.
- Import checks the one-megabyte size boundary before parsing, requires a supported positive schema
  version, decodes the profile, and then validates its semantics.
- Imports reject an empty profile name; empty or duplicate rule IDs; non-positive minimum lengths;
  negative maximum lengths; invalid regular expressions; missing or empty allowed values; and a
  dependency that points a field at itself.
- Newer schemas are rejected with the shared read-only schema error instead of being interpreted by
  an older build.

The file service is intentionally independent of settings and UI. Caption Workspace, Deadline Mode,
and future assignment packages can add selection and management surfaces while using the same
validated file boundary.

## Reference fixture

`Aagedal Photo Agent Tests/Fixtures/EditorialMetadata/newsroom-validation-profile.json` is a CC0
synthetic desk profile. It contains all seven rule kinds and fictional policy values. The fixture is
listed in the corpus manifest and its canonical export must remain byte-identical, making accidental
JSON contract drift visible in tests.

## Automated validation

The following focused macOS test command passed:

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataValidationTests'
```

Result: `MetadataValidationTests` passed 12 tests with no failures. Coverage includes the shared rule
engine, legacy requirement migration, canonical Digital Source Type comparison, placeholder
detection, schema safety, synthesized-rule migration, canonical fixture encoding, atomic file
replacement, semantic rejection, and size/schema boundaries.
