# ADR-001 — Analysis and named-version storage locations

**Status:** accepted for 3.0
**Decision date:** 2026-08-23
**Recorded:** 2026-08-24

## Decision

Analysis cases and working-folder map state use app-private, versioned JSON in the photo folder's
`.photo_analysis` directory. Named Develop versions use app-private, source-bound JSON catalogs in
`.photo_versions/catalogs`, with catalog filenames derived from the authoritative source SHA-256.
Neither store is part of IPTC/XMP metadata, and ordinary case or named-version saves do not modify
the source image or its XMP sidecar.

When the photo folder is known to be read-only, or a folder-local write fails specifically because
permission is denied or the volume is read-only, the repositories use indexed Application Support
fallback stores:

- `AnalysisCases` for analysis cases and working-folder map documents; and
- `DevelopVersions` for named-version catalogs.

Fallback state remains editable but local to the current Mac. The workspace must show a portability
warning instead of implying that fallback data travels with the photo folder. An equal-revision
folder-local analysis document takes precedence over its fallback copy.

All of these documents use the shared atomic JSON boundary: validate a sibling staging file,
synchronize it, preserve the previous valid primary as one bounded backup, and then atomically
replace the destination. A corrupt primary may load from its valid backup. A newer unsupported
schema is retained intact for read-only handling and cannot be overwritten by an older writer.

## Rationale

Folder-local app data keeps an investigation or named edit catalog portable with its photographs
without putting private workflow state into interoperable metadata. A narrow Application Support
fallback keeps those workflows usable on read-only folders while making the loss of portability
explicit. Versioned atomic JSON with a single backup gives both repositories the same failure and
downgrade boundary.

## Consequences

- Backup, rename, move, reject, and folder-monitor workflows must treat `.photo_analysis` and
  `.photo_versions` as app-owned companion stores.
- Fallback indexes retain enough original folder and source identity to find local-only records.
- Fallback is not a portable-settings or metadata synchronization mechanism.
- Permission failures outside the approved fallback errors remain visible failures; repositories
  do not silently redirect every write error.
- A future store location or synchronization policy requires a new ADR and migrations rather than
  an undocumented path change.

## Implementation evidence

- [Storage and architecture](storage-and-architecture.md#proposed-folder-layout)
- [Analysis-case read-only-folder fallback validation](analysis-case-fallback-validation.md)
- [Named-version workflow validation](phase-10-version-workflow-validation.md)
- `AnalysisCaseRepository`, `DevelopVersionCatalogRepository`, and `AtomicJSONDocumentStore`
