# Known People companion interchange

Status: coordinated design with strict FEM2 admission implemented locally; manual
package implementation is gated on the two compatibility decisions below. Automatic
local sharing is a later opt-in phase.

## Ownership and phases

Photo Agent is the only editor and publisher. FTP Sync consumes an immutable
snapshot for matching and may re-export the exact imported snapshot bytes. It must
never edit Photo Agent's live Known People store or infer deletions from a partial
directory view.

1. Ship a verified `.aagedalpeople` package with manual export/import in both apps.
2. Add separately consented local sharing after both signed targets have the same
   macOS App Group entitlement. Publish a fully staged immutable snapshot, then
   atomically replace one `current` revision pointer. Readers retain the revision
   they admitted; a failed publication leaves the previous revision active.
3. Consider cloud exchange separately. An App Group is local transport, and the
   existing Known People iCloud consent does not authorize cross-app sharing.

Disabling local sharing stops future publication and reads. The UI must explain any
retained companion copy and offer to remove that copy without deleting Photo Agent's
source database.

## Shared matching projection

The core follows FTP Sync's provisional schema-2 reader at source revision
`0c37b2f78752a51eaa765445afd5cc801dbf0a3d`:

- `manifest.json`: `format` = `aagedal-known-people`, `schemaVersion` = 2,
  persistent lowercase `libraryID`, content-derived lowercase SHA-256 `revision`,
  exact UTC `exportedAt`, exporter identity, embedding contract, counts and the
  sorted inventory of every payload file with byte count and SHA-256.
- The embedding contract is version 3, component
  `auraface-r100-coreml`, model `AuraFace-v1/glintr100`, preprocessing
  `photo-agent-eyes112-rgb-v3`, encoding `fem2-float32-le`, dimension 512 and
  L2-normalized true.
- `people.json` contains stable lowercase person IDs, names and one or more examples.
  Example IDs point to `embeddings/<id>.fem2`; optional person and example JPEGs use
  the corresponding canonical UUID paths under `thumbnails/` and
  `embedding_thumbnails/`.
- FEM2 is exactly 2,056 bytes: little-endian magic `0x46454d32`, little-endian
  dimension 512, and 512 finite little-endian Float32 values. Reject a zero vector
  or an incoming norm more than 0.0001 from 1; normalize only accepted rounding drift.
- `revision` hashes sorted-key, unescaped-slash UTF-8 JSON of format, schema version,
  library ID, contract, counts and the ASCII-path-sorted file inventory. Export time
  and exporter identity do not affect it.

Honor the companion limits: 10,000 people, 100,000 examples, 200,001 files,
16 MiB for each file/manifest/people payload and 500 MB total. Reject blank/NUL/overlong
names, duplicate IDs or JSON keys, unknown keys, trailing JSON, excessive nesting,
symlinks, noncanonical/case-variant paths, undeclared/unreferenced files and hash,
size, count or revision mismatches. Every shared person must have an example.

The package is a ZIP-compatible archive with `.aagedalpeople` as its user-facing
extension and the files above at its root. Extraction must enforce the same path and
size policy before the existing validated-directory reader is invoked.

## Lossless Photo Agent extension

The shared projection does not carry Photo Agent's role, notes, timestamps,
representative thumbnail choice or per-example source/time/mode fields. Schema 2
therefore needs one coordinated optional descriptor before lossless interchange can
ship:

```json
"editorPayload": {
  "path": "editor/photo-agent.json",
  "mediaType": "application/vnd.aagedal.photo-agent-known-people+json;version=1",
  "byteCount": 123,
  "sha256": "..."
}
```

The descriptor and file are included in the full inventory and snapshot revision. FTP Sync
validates the exact path, size and hash, stores the bytes opaquely, and re-exports
them unchanged. Photo Agent validates an editor envelope bound to the same library ID
and a separate `matchingProjectionSHA256`. That digest uses the revision algorithm's
canonical input with the editor descriptor/file excluded, avoiding a circular dependency;
the final snapshot revision includes the editor descriptor and file. The payload preserves
exact per-person record JSON bytes keyed by person ID, preventing a newer Photo Agent field
from being discarded by an older decoder. The shared person/example IDs and matching
projection must agree with those records.

FTP Sync's current strict validator rejects this key and path, so Photo Agent must not
emit the extension until the companion implementation accepts and preserves it.

## Photo Agent admission and replacement

Export captures one immutable view under the existing process-wide Known People
storage ownership: routing generation, persistent library identity, raw person bytes,
tombstone state and referenced thumbnails. Existing but unreadable records, ambiguous
tombstones, partial iCloud downloads, invalid embeddings or unreadable referenced
thumbnails fail the full snapshot. A truly absent optional thumbnail is omitted.
Stage, validate and atomically install the destination; cancellation or failure keeps
any prior export intact.

Import is an explicit snapshot replace/merge decision separate from the legacy ZIP
command. Replacement is required for rename and removal semantics, including a valid
empty snapshot. A stale or different library identity requires a visible decision;
it must not overwrite newer edits automatically. Preserve the previous database until
all package files and editor metadata are validated and the replacement can commit.
The legacy ZIP remains an additive, unseen-UUID import for compatibility and must stay
visibly labeled as such.

Photo Agent's global embedding-version stamp is insufficient provenance for records
imported from the legacy ZIP format: that manifest was ignored and its embeddings had
no per-library space identity. Valid FEM2 shape does not prove AuraFace-v3 origin.
Before full-library v2 export, require either durable compatible provenance established
at creation/import or an explicit re-enrollment/compatibility decision that cannot be
mistaken for cryptographic proof.

## Verification gate

Required automated evidence includes a cross-repository golden package and revision,
FEM2 byte vectors, stable re-export despite different export timestamps, rename/remove
revision changes with stable library identity, exact opaque editor round trip, valid
empty replacement, malformed-vector/provenance refusal, archive traversal/symlink/bomb
limits, concurrent CRUD/root switching, cancellation around atomic publication and
tampered hash/count/revision failures.

Required integrated evidence is Photo Agent export, FTP Sync admission and matching,
FTP Sync byte-exact re-export, Photo Agent lossless restore, and removal/rename
replacement while an already running FTP operation retains its admitted old snapshot.
For automatic sharing, verify effective signed entitlements and upgrade behavior on
supported macOS releases before enabling the preference.

## 2026-09-12 implementation checkpoint

`FaceEmbeddingInterchangeCodec` now implements the shared fixed-size little-endian
FEM2 admission independently from Photo Agent's permissive internal compatibility
decoder. It rejects malformed byte counts, magic/dimension mismatches, NaN/infinity,
zero and non-normalized vectors, and normalizes only accepted floating-point drift.
It explicitly leaves model/preprocessing provenance to whole-library admission.

Independent source review confirms the implementation matches FTP Sync's current FEM2
reader. The focused FaceEmbedding suite passes 23 tests / one suite in 0.141 seconds
(`build/qa-known-people-interchange-focused-v3.log`), including direct untrusted-wire
failures and exact header/value bytes. Repository validation passes in
`build/qa-known-people-interchange-repository.log`. Two earlier focused attempts are
retained in the ignored build directory: the first exposed incorrect Swift catch syntax;
the second exposed unsupported closure syntax in a new assertion. Both were test-code
errors corrected before the passing run; no product assertion was weakened.
