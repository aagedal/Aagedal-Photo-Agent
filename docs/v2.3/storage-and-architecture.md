# Version 2.3 — storage and architecture

## Goals

- Keep analysis, comparison, and version data separate from IPTC metadata and Adobe-compatible XMP.
- Tie persisted state to exact source bytes.
- Make every write atomic and recoverable.
- Share orientation and viewport logic across the new features.
- Keep feature ownership out of `ContentView`.
- Preserve forward compatibility by retaining unknown JSON fields where practical or refusing a
  destructive downgrade.

## Proposed folder layout

Preferred folder-local layout:

```text
Photo Folder/
├── IMG_0001.CR3
├── IMG_0001.xmp
├── .photo_metadata/
├── .face_data/
├── .photo_analysis/
│   ├── index.json
│   ├── cases/
│   │   └── <case-uuid>.analysis.json
│   ├── previews/
│   │   └── <case-uuid>/...
│   └── reports/                 # optional user choice; not required for case validity
└── .photo_versions/
    ├── index.json
    └── catalogs/
        └── <source-identity>.versions.json
```

Use Application Support fallback when the source folder is read-only. The fallback index must
record the original folder/source identity and offer a user-visible portability warning. Do not
silently fail or repeatedly request folder access.

Before adopting new hidden folder names, verify backup, move-to-folder, move-rejected, rename,
delete, iCloud, and folder-monitor behaviors. Sidecar-aware file operations must either move the
associated analysis/version records transactionally or deliberately leave a recoverable record and
explain it.

## Source identity

Path alone is not identity. Each persisted feature uses:

```text
SourceImageRevision
  canonicalURL
  fileResourceIdentifier?     // fast same-volume rename/move aid
  filenameAtCreation
  byteCount
  contentModificationDate
  pixelWidth?
  pixelHeight?
  exifOrientation?
  sha256
  hashCompletedAt
```

Rules:

- SHA-256 is authoritative for exact revision matching.
- Resource ID and filename are discovery hints only.
- Size/date can determine that a hash cache is reusable, but not prove content equality after an
  untrusted external change.
- Store hashes as lowercase hex with an algorithm prefix or separate algorithm field.
- Hashing is cancellable and streamed; never load a large RAW file into one `Data`.
- A file move can reassociate automatically only when the hash matches.

## Analysis schema sketch

This is a conceptual schema. Formalize it with Codable types and migration tests before UI work.

```json
{
  "schemaVersion": 1,
  "id": "UUID",
  "title": "Case title",
  "source": {
    "sha256": "...",
    "byteCount": 123,
    "filenameAtCreation": "IMG_0001.CR3"
  },
  "createdAt": "ISO-8601",
  "updatedAt": "ISO-8601",
  "appBuild": "428",
  "displayPreference": "original",
  "analyzerRuns": [
    {
      "analyzerID": "metadata-consistency",
      "analyzerVersion": 1,
      "parameters": {},
      "status": "complete",
      "sourceRepresentation": "originalBytes",
      "findings": []
    }
  ],
  "annotations": [],
  "calibrations": [],
  "mapEvidence": [],
  "userNotes": [],
  "reportSelections": {}
}
```

Large generated previews and raster overlays should be content-addressed external files, not base64
inside the main JSON. Each attachment entry records SHA-256, format, pixel dimensions, analyzer
version, and whether it is reproducible. Reproducible caches may be deleted; user-authored evidence
must not be treated as disposable cache.

## Version catalog schema sketch

```json
{
  "schemaVersion": 1,
  "source": {
    "sha256": "...",
    "byteCount": 123,
    "filenameAtCreation": "IMG_0001.CR3"
  },
  "activeVersionID": "UUID or null for Primary",
  "defaultVersionID": "UUID or null",
  "versions": [
    {
      "id": "UUID",
      "name": "Warm editorial",
      "createdAt": "ISO-8601",
      "updatedAt": "ISO-8601",
      "createdByAppBuild": "428",
      "settingsSchemaVersion": 1,
      "settings": {},
      "notes": null,
      "dependencyManifest": []
    }
  ]
}
```

Do not serialize `Primary` as a duplicate named version on every save. It is a virtual catalog
entry backed by current XMP state. Store a recovery snapshot only for explicit cross-boundary
operations such as promotion.

## Annotation schema

Use a tagged shape:

```text
Annotation
  id
  surface: photo | map
  shape:
    photoLine(normalizedStart, normalizedEnd)
    photoRect(normalizedRect)
    photoEllipse(normalizedRect)
    photoLabel(normalizedAnchor, leaderEnd?)
    mapLine(coordinates[])
    mapPolygon(coordinates[])
    mapCircle(center, radiusMeters)
    mapMarker(coordinate)
  labelID                  // visible stable number/text
  text
  color
  strokeWidth
  fillOpacity
  hidden
  sourceOrientationAtCreation?
  sourcePixelSizeAtCreation?
  createdAt / updatedAt
```

Photo coordinate origin and axis direction must be documented once and used by markup, comparison,
true-pixel hover, report rendering, and crop transforms. Prefer top-left origin normalized display
coordinates if that matches current overlays, with explicit conversions at Core Image/Metal/CG
boundaries.

## Shared viewport

```text
ViewportState
  mode: fit | actualPixels | custom
  normalizedCenter: (x, y)
  pixelsPerBackingPixel
  interpolation
  viewSize

SynchronizedViewport
  anchorPane
  locked
  normalizedOffset
  scaleRatio
  transactionID
```

The transaction ID (or equivalent coordinator guard) prevents A updating B, then B echoing the
clamped state back into A indefinitely.

`DisplayImageTransform` should own:

- EXIF sensor-to-display point/rect mapping;
- displayed pixel dimensions;
- developed crop/straighten mapping when selected;
- normalized image rect within a viewport;
- view point ↔ normalized display point;
- normalized display point ↔ source pixel;
- backing scale and true-pixel reporting.

Tests must cover all eight EXIF orientations, non-square pixels if supported, mirrored images,
straightened crops, and boundary clamping.

## Analyzer architecture

Use a narrow protocol:

```text
AnalysisAnalyzer
  identifier
  version
  costClass
  requiredInput
  analyze(context, parameters) -> streamed progress/result
```

Input classes should distinguish:

- original byte stream;
- raw metadata graph;
- oriented decoded original;
- developed rendering;
- low-resolution preview;
- map/time context.

An analyzer must declare which input it used so the UI/report cannot accidentally describe a
developed-render result as a source-byte observation.

The runner owns prioritization, cancellation, deduplication, cache lookup, and result publication.
Analyzers must not mutate the case directly.

## Persistence

### Atomic write sequence

1. Encode and validate the next document in memory or a bounded stream.
2. Write to a sibling temporary file.
3. `fsync`/close as appropriate.
4. Decode the temporary file and validate schema/invariants.
5. Preserve the previous valid file as a bounded backup.
6. Atomically replace the destination.
7. Notify folder monitors as one logical change.

Never overwrite the only valid case/catalog before the replacement is verified.

### Concurrency

- One actor/service owns writes for a particular case/catalog.
- UI edits can be debounced, but navigation/quit flushes are explicit.
- External file changes trigger compare/reload/conflict state, not last-writer-wins.
- Case and catalog writes use coordinated I/O where iCloud or shared volumes require it.
- Background analyzers publish immutable results back through the case owner.

### Migrations

- Every top-level JSON document has a schema version.
- Migrations are pure and tested from every shipped schema.
- A newer unsupported schema opens read-only; do not rewrite it with an older schema.
- The shared store returns the complete bytes of a newer schema for that read-only path and rejects
  every attempted save until a compatible reader is available.
- Writers must bump the schema when adding fields that an older build cannot safely round-trip.
  The default decoder accepts only its current schema; each feature must opt into and test older
  schema migration explicitly.
- Preserve the pre-migration file until the migrated file validates.
- Settings payload migrations are separate from catalog migrations.

## Dependency manifest

Named versions can reference external resources:

| Dependency | Identity |
|---|---|
| Watermark | library UUID plus asset content hash |
| LUT | embedded data hash or library reference plus hash |
| AI mask | embedded/case attachment hash |
| Preserved correction | source-bound payload checksum |

On open:

- resolved and matching;
- resolved but changed;
- missing;
- unsupported.

Never substitute a different asset with the same filename without warning.

## Security and privacy

- Core analysis remains on-device.
- Any future network analyzer needs per-feature consent, a clear disclosure of transmitted data,
  retention terms, and an option to send no source pixels.
- Map/place requests are separate from pixel analysis and should follow existing geocoding settings
  where appropriate.
- Reports can contain precise coordinates, serial numbers, faces, hashes, and private notes. Warn
  before export and provide inclusion toggles for sensitive fields.
- Analysis JSON may contain sensitive assertions; do not opt it into portable iCloud settings sync.
- Clean temporary report/previews on success and bounded-age cleanup after crashes.
- Do not log raw metadata values, coordinates, source paths, or case notes at normal log levels.

## Integration audit

Before implementation completes, review:

- `ContentView` navigation and toolbar branching;
- `BrowserPanesModel` active-pane ownership;
- `BrowserViewModel` selection/order and file operations;
- folder change monitor exclusions/invalidation;
- recent/favorite/security-scoped folder handling;
- metadata sidecar reconciliation;
- XMP read/write and unknown correction preservation;
- Develop preview/render token generation;
- full-screen dedicated window lifecycle;
- Clean Feed source contract;
- thumbnail and scope cache invalidation;
- move/rename/trash/reject workflows;
- backup/import behavior for hidden app data;
- app quit/background operation monitor;
- Settings portable-sync allowlist;
- release cleanup and license attribution for any new model/binary.

## Failure states

Every feature needs explicit UI for:

- source offline/not downloaded;
- folder permission missing;
- source changed;
- case/catalog corrupt with backup available;
- case/catalog newer than app;
- analyzer cancelled/failed/unsupported;
- map offline or imagery unavailable;
- report cannot include licensed imagery;
- named version dependency missing;
- JSON write failed/read-only destination;
- XMP promotion failed or read-back mismatched;
- comparison source missing or decode failed;
- insufficient memory/GPU capability.
Failure should preserve access to notes, findings, and valid prior versions wherever possible.
