# Frozen delivery plan validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 immutable, resumable plan boundary before staging

## Implemented contract

- `DeliveryPlanningService` freezes the exact Deadline profile, preflight revision and semantic
  result, source revisions, resolved metadata, output filenames, export/write/GPS settings,
  destination UUID/resolved path, accepted warning IDs, and optional Develop snapshots.
- The plan and each staging item receive deterministic SHA-256 fingerprints. Revalidation rejects
  profile/preflight/source/metadata/Develop/rename drift, duplicate or unsafe paths, fingerprint
  tampering, blocking preflight issues, and warnings that were not explicitly accepted.
- Per-item stage inputs contain everything a later bounded staging executor needs without
  consulting mutable UI state. Connection references must be canonical UUIDs; no credential,
  host/user configuration, bookmark, or Keychain value is representable.
- Strict versioned JSON import/export validates the semantic plan, rejects unsupported newer
  schemas before decode, enforces a file-size bound, and never overwrites an existing destination.

## Test evidence

```sh
xcodebuild test -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-delivery-plan-build-01' \
  -only-testing:'Aagedal Photo Agent Tests/DeliveryPlanningServiceTests'
```

Result: **8 tests passed** and the app/test dependency graph compiled successfully. PBX parsing and
`git diff --check` also passed.

## Remaining integration

- Execute the plan through staged copy/render, metadata write, byte read-back, verification,
  upload, and atomic receipt services.
- Connect plan confirmation and warning acceptance to Deadline Workspace only after all live
  preflight adapters provide captured facts.
