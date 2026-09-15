# FTP Sync handoff: People Library schema 3

Implement import and export support for Photo Agent's People Library schema 3 while retaining full schema 2 support. This is an interchange-format change, **not** a new face-recognition model or embedding contract. Do not add a model picker or re-embed faces as part of this work.

## Compatibility contract

- Accept `manifest.json` with `schemaVersion` 2 or 3. Keep existing schema 2 golden fixtures and canonical revision results unchanged.
- Emit schema 2 when an exported package has no `upgrade_sources/` files. Emit schema 3 when it has at least one. A schema 3 reader may accept a valid package with no crops, but Photo Agent's writer chooses schema 2 in that case.
- Schema 2 must reject `upgrade_sources/` declarations/files. Never silently ignore a schema 3 crop-bearing package or down-convert it to schema 2 while losing crops. If FTP Sync cannot durably retain crops yet, fail that import/export with a clear explanation.
- The current AuraFace embedding contract and FEM2 vector format do not change. Upgrade crops are optional source material for a future model transition, not thumbnails for matching or a second embedding space.

## New schema 3 data

For each object in `people.json`'s `people[].examples[]`, add an optional `upgradeSourcePath` string. When present it must be exactly `upgrade_sources/<example-id-lowercase-uuid>.jpg`. Its ID must equal the example's `id`, just as `embeddingPath` and optional `thumbnailPath` do. A package can mix examples with and without crops.

Example (other example fields may also be present):

```json
{
  "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
  "embeddingPath": "embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2",
  "upgradeSourcePath": "upgrade_sources/cccccccc-cccc-cccc-cccc-cccccccccccc.jpg"
}
```

Every crop must be declared in `manifest.json`'s `files[]` with its exact byte count and SHA-256, and referenced by exactly one example. Conversely, every non-optional file declaration must be referenced as before. Allow the new folder in both directory-package and ZIP path allow-lists; preserve the existing no-traversal, no-links, no-extra-files rules. The crop must be a complete, decodable single-frame `public.jpeg`, exactly 320×320 pixels, and at most 1,000,000 bytes. The general manifest per-file ceiling remains 16,777,216 bytes, but crop validation is tighter.

Photo Agent's current package ceilings are 10,000 people, 100,000 embeddings, 300,001 declared files, and 500,000,000 total declared-file bytes. The ZIP transport is still the strict stored ZIP32 profile, at most 536,870,912 archive bytes and 65,534 entries; directory packages are the fallback only **within** the 500 MB package ceiling. Do not increase these limits casually without a streaming/memory review.

## Revision and editor metadata

Schema 3 uses the same canonical JSON and hashing algorithms as schema 2, but the **actual schemaVersion (2 or 3)** is included in both revision inputs. `coreRevision` hashes the canonical input containing `format`, `schemaVersion`, lowercase `libraryID`, unchanged embedding `contract`, `peopleCount`, `embeddingCount`, and ASCII-path-sorted `files[]` excluding `editor/photo-agent.json`. `revision` hashes the canonical snapshot input containing `format: "aagedal-known-people-snapshot"`, `schemaVersion`, `coreRevision`, and the optional editor-payload descriptor. Use sorted JSON keys and unescaped slashes exactly as the schema 2 implementation does.

Adding/removing a crop changes `coreRevision` even when FEM2 vectors are unchanged. If FTP Sync rebuilds a package with editor metadata, regenerate the editor payload with the new `coreRevision`, then its descriptor and final `revision`. Do not copy an editor payload bound to a prior core revision into a rebuilt schema 3 package.

## Storage and privacy behavior

FTP Sync does not need to *generate* face crops, but a successful schema 3 import must keep crop bytes associated with their example IDs so a subsequent export can retain them losslessly. Preserve valid crop bytes rather than recompressing. Removing an example/person or replacing the library must remove its no-longer-referenced crops. If FTP Sync has no retention or sync UX for these sensitive JPEGs, add accurate disclosure before shipping; do not silently upload them under wording that only mentions vectors/thumbnails. Keep legacy additive ZIP behavior separate from People Library schema 3.

## Acceptance tests

1. Existing schema 2 directory and ZIP golden fixtures still import and re-export with unchanged canonical revisions; a no-crop export remains schema 2.
2. A schema 3 package with one crop imports from directory and ZIP, retains the exact crop bytes and example UUID association, and re-exports valid schema 3 bytes. Test mixed examples with/without crops.
3. Reject missing, unreferenced, duplicate, hash-mismatched, oversized, non-JPEG, corrupt, or non-320×320 crops; wrong UUID/path; schema 2 with crop files; symlinks/traversal/unsafe ZIP entries.
4. Test crop addition/removal recomputes `coreRevision`, editor `coreRevision`, editor descriptor, and `revision` correctly without changing the schema 2 golden result.
5. Ensure deletion/replacement and any FTP Sync cloud path do not leave orphaned crop data or silently strip it from later exports.

Photo Agent implementation references: `Aagedal Photo Agent/Services/KnownPeoplePackageManifest.swift` (schema, paths, revision), `KnownPeopleUpgradeSourceStore.swift` (JPEG admission), `KnownPeoplePackageArchive.swift` and `KnownPeoplePackageDirectoryReader.swift` (transport admission), `KnownPeopleLocalStoreSnapshotBuilder.swift` (export), and `Aagedal Photo Agent Tests/KnownPeopleLocalStoreSnapshotBuilderTests.swift` (`upgradeSourceRoundTrip`). Treat the Photo Agent implementation as the current reference; coordinate a shared schema 3 fixture/test corpus between both apps before release.
