# Metadata JSON persistence validation

**Date:** 2026-08-19  
**Scope:** journalistic metadata workflow, Phase 1 model and persistence

## Implemented behavior

- App metadata sidecars, metadata templates, and template export bundles write an explicit,
  positive `schemaVersion`.
- Existing sidecars using `version: 1` and existing unversioned templates decode into the current
  model with safe defaults.
- The earliest template shape using `presetType`, templates predating shortcut slots, and templates
  predating instant variable processing migrate without user action.
- A document declaring a newer schema is never quarantined as corrupt and cannot be overwritten by
  this build.
- Same-schema unknown fields at the sidecar and metadata levels survive ordinary edits, while an
  omitted known optional field remains an explicit clear rather than being merged back.
- A filename-only rename of a newer app sidecar changes only `sourceFile` and retains the otherwise
  unknown JSON object graph.
- Malformed sidecars retain the existing recoverable `.corrupt.<timestamp>` quarantine behavior.

## Automated validation

The following focused macOS test command passed:

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataSidecarServiceTests' \
  -only-testing:'Aagedal Photo Agent Tests/MetadataTemplatePersistenceTests'
```

Results after the final preservation cases:

- `MetadataSidecarServiceTests`: 27 tests passed.
- `MetadataTemplatePersistenceTests`: 4 tests passed.
- Total: 31 tests passed with no failures.

This validates the app-owned JSON boundary only. XMP/IPTC-IIM mappings, external Bridge and Photo
Mechanic round trips, and the IPTC interoperability corpus remain separate Phase 0/1 exit gates.
