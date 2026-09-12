# Known People companion interchange

Status: coordinated schema, strict FEM2/provenance admission, and a verified directory
package reader are implemented locally. Manual interchange remains gated on transactional
Photo Agent replacement/export, archive and UI adapters, and legacy-sample disposition.
Automatic local sharing is a later opt-in phase.

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

The core follows FTP Sync's schema-2 package slice committed at source revision
`2dc18e9c4df7328eb59cb0503d7febcbad4acd56` (contract docs `8ca3c77`):

- `manifest.json`: `format` = `aagedal-known-people`, `schemaVersion` = 2,
  persistent lowercase `libraryID`, content-derived lowercase SHA-256 `coreRevision`
  and overall `revision`,
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

Honor the companion directory-package limits: 10,000 people, 100,000 examples,
200,001 files, 16 MiB for each file/manifest/people payload and 500 MB total. Reject blank/NUL/overlong
names, duplicate IDs or JSON keys, unknown keys, trailing JSON, excessive nesting,
symlinks, noncanonical/case-variant paths, undeclared/unreferenced files and hash,
size, count or revision mismatches. Every shared person must have an example.

The primary package is a directory bundle with the exported type identifier
`no.aagedal.people-library`, conforming to `com.apple.package`, and the user-facing
extension `.aagedalpeople`. A transport archive uses the distinct compound extension
`.aagedalpeople.zip`, with the package files at the archive root. Import accepts both
forms. The strict ZIP32 transport supports at most 65,534 entries because `0xffff` is
reserved as the ZIP64 sentinel; larger valid libraries must use the directory package.
ZIP extraction enforces the directory package's path, per-file and total-size policy
before the existing validated-directory reader is invoked. ZIP bytes must never be
written under the bare package extension. Both apps and their UI must present the same
archive limit and direct larger libraries to the directory form.

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
and `coreRevision`. That digest uses the revision algorithm's canonical input with the
editor descriptor/file excluded, avoiding a circular dependency; the final snapshot
revision includes the editor descriptor and file. The payload preserves
exact per-person record JSON bytes keyed by person ID, preventing a newer Photo Agent field
from being discarded by an older decoder. The shared person/example IDs and matching
projection must agree with those records.

FTP Sync has now committed this additive contract and exact-byte preservation after its
full suite passed 1,030 tests with 15 opt-in skips and zero failures. Per-example `recognitionMode` is exactly
`vision` or `faceClothing`, matching `FaceRecognitionMode` raw values. Photo Agent must
still complete its provenance/import transaction before presenting the format. FTP Sync's
committed slice does not yet claim ZIP/UI/App Group support.

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

The first replacement implementation must be local-store only. Package revisions are
content hashes rather than ordered versions, and `exportedAt` does not prove ancestry.
Preflight therefore needs an exact, non-mutating inventory token for the current root and
an explicit same-library, different-library or previously untracked replacement decision;
commit must reject any root change after that decision. Persist `libraryID`, installation
identity, admitted contract and imported revisions in a strict root-local state record.
Keep the admitted raw package bytes available for exact re-export, and treat them as the
current projection only while a digest of the managed person and thumbnail files still
matches. A missing identity means a legacy/untracked store, while malformed identity blocks
replacement planning.

Do not derive replacement state from `KnownPeopleService.loadDatabase()`: that compatibility
path can migrate, resolve conflicts, collect tombstones and omit unreadable records. Stage a
complete replacement, including a valid empty database, read it back, retain the previous
tree as rollback evidence and install through a tested directory transaction. Root-local
contract evidence must also prevent the global embedding migration stamp from resetting a
newly admitted current package. Whole-root commit must invalidate every peer cache/read
generation and discard or generation-scope thumbnail deletions admitted against the old tree.

Current iCloud routing performs preserve-newer tree merges outside the service's import
reservation, and the iCloud daemon is not stopped by process-local locks. Replacement must
refuse while Known People iCloud sync or routing is active, and later cloud enablement must
refuse a locally replaced state marked as needing reconciliation. Cloud replacement requires
a separate immutable-generation publication protocol so an old record cannot resurrect after
an empty or removal-bearing snapshot.

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

Fresh face detection now obtains provenance only from an embedder that explicitly
declares it, validates the produced FEM2 bytes, stores it with `DetectedFace`, and copies
that exact optional value into `PersonEmbedding`. Photo Agent's production CoreML embedder
declares the current embedding-space version, component, model, preprocessing, wire
encoding, dimension and normalization contract. Alternate embedders default to unknown.
The optional fields are backward-decodable; legacy/foreign cached faces and Known People
records remain nil/unknown rather than inheriting trust from matching dimensions, a global
preference or the Add Group action. The package exporter must reject or visibly resolve
those unknown samples.

`KnownPeopleInterchangeEligibility` now applies the companion's person/example limits,
name rules, nonzero/global ID uniqueness, nonempty-example requirement, exact current
provenance and strict FEM2 admission before projection. It permits an empty authoritative
snapshot, which is required to represent a deliberately cleared library without tombstone inference.

Independent source review confirms the strict codec matches FTP Sync's current FEM2
reader. The initial codec checkpoint passes 23 tests / one suite in 0.141 seconds
(`build/qa-known-people-interchange-focused-v3.log`). The corrected generation-to-addition
provenance follow-up passes 25 tests / one suite in 0.135 seconds
(`build/qa-known-people-interchange-focused-v5.log`), including direct untrusted-wire
failures, exact header/value bytes, legacy nil provenance and exact fresh-face propagation.
The Known People service suite separately passes 64 tests / one suite in 14.124 seconds
(`build/qa-known-people-interchange-service.log`). Repository validation passes in
`build/qa-known-people-interchange-repository-v4.log`. Two earlier focused attempts are
retained in the ignored build directory: the first exposed incorrect Swift catch syntax;
the second exposed unsupported closure syntax in a new assertion. Both were test-code
errors corrected before the passing run; no product assertion was weakened.

The final eligibility follow-up passes 26 tests / one suite in 0.116 seconds
(`build/qa-known-people-interchange-focused-v8.log`), including zero IDs, multibyte
name boundaries and the people-count limit. Intermediate v7 exposed a misplaced new
guard as a compile error; it was moved inside the embedding loop before v8 passed.
FTP Sync's strengthened cross-repository golden directory is pinned at commit `da3579e`. Its library,
person and example identities are `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa`,
`bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb` and
`cccccccc-cccc-cccc-cccc-cccccccccccc`. Photo Agent's decoded fixture files exactly match
the companion SHA-256 values: manifest
`9b3f1bb062b98b6482c9e8e0853b440aa88a1203beba738d006330ac04bf794d`, people
`defe59be76163a68585a9d56a54ab55ffd54385fb72167a400e634f9fd24a901`, editor
`3135e29a2ba54766bc199d2c9e486aec39b94c66289f098fd26cde9828fb5efb`, and FEM2
`11515e45513a5f28a7e15321d1caa573c3dc1e70a112ac813dd8019f2900f1be`.
The FEM2 wire values begin with 0.60003 and 0.8: they are within the shared norm
tolerance, but normalizing and re-encoding changes the bytes. This makes silent
decode-normalize-re-encode drift observable.
The fixture pins core revision
`636f498dba7a9bb357ece23e2f5edcd02997fb4df1acc1e1101eecfd32438e83`
and overall revision
`12324ae00b79094d239447531d81348e4c6450b7a65fbc329daab261c08025ba`.

`KnownPeoplePackageDirectoryReader` now admits the directory form through held directory
descriptors, `openat` and no-follow reads. It rejects non-regular or multiply linked files,
undeclared/missing carriers, unsafe paths, size/hash/revision/count/schema/editor-coverage
failures, invalid JPEGs and malformed FEM2 before projecting a `KnownPerson`. It assigns
current provenance only after the manifest's exact embedding contract and each FEM2 payload
pass. The immutable snapshot retains every admitted source byte, including the original
manifest, people and editor JSON, for a future lossless re-export. Missing editor metadata
remains explicit; deterministic fallback dates come from `exportedAt`.

Independent source review passes. The reader follow-up passes 10 tests / one suite, including
valid empty replacement candidates and root-symlink refusal. `KnownPeoplePackageDirectoryWriter`
revalidates the immutable snapshot, stages only exact captured bytes beside the destination,
admits no-follow leaves, reads the complete stage back, and installs through exclusive rename or
atomic directory swap. It reports the rename as committed before any later fallible sync or cleanup,
and retains the prior directory as explicit recovery evidence after post-commit failure or cancellation.
Its retained parent descriptor and advisory lock serialize cooperating writer instances and keep
relative operations attached to the admitted parent if its pathname is moved. Non-cooperating
same-user mutation remains outside the whole transaction guarantee because POSIX provides neither
atomic compare-and-swap admission nor compare-and-unlink cleanup; repeated boundary identity/readback
checks turn observed mutations into failures and preserve recovery evidence. The writer suite passes
13 tests across 37 parameterized cases, covering new and replacement export,
pre/post-commit faults, deterministic cancellation, forged snapshots, aliases/nesting, nested and
inside/post-install mutation, parent retargeting/counterfeit entries, missing cleanup ownership, and
cooperating-writer serialization. Repository validation passes after one transient
`lipo` inspection failure on the unchanged bundled ffmpeg; an immediate direct probe and
complete rerun passed. Earlier focused attempts exposed sandbox cache denial, a POSIX `read`
name collision and a nested test macro; each was corrected without weakening product
admission or assertions. The strict ZIP32 archive, managed-store replacement and local
snapshot builder now form the verified Photo Agent core boundary. The archive validates
headers, inventory, hashes, CRC, JPEG and FEM2 before extraction and retains truthful
cleanup/recovery evidence. Managed replacement holds the route and complete local root,
rechecks descriptor-bound inventory, atomically swaps the projection, preserves exact admitted
package bytes, invalidates stale deferred work and blocks iCloud enablement until explicit
reconciliation. Local capture rejects unsafe, changed or untracked roots and reuses admitted
bytes only while both package and managed-projection hashes still bind. Service-local UUID
filenames use uppercase `UUID.uuidString`; interchange paths remain lowercase. The integrated
five-suite checkpoint passes 149 declared tests across 346 expanded cases, and the independent
source audit approves the implementation. Atomic first-time identity assignment now builds a
canonical package from an untracked populated or empty local root, binds the complete captured
inventory before and after planning, retains stable library and installation IDs across safe
precommit retry, and commits only through the existing whole-root owner gateway. A committed or
uncertain result is retained and never replayed. Identity, builder and managed replacement pass
46 declared tests across 84 expanded cases with independent approval. High-level package
admission/export APIs, the explicit local-to-cloud reconciliation workflow, user-facing
export/import adapters and App Group publication remain.

The contradictory older local AuraFace package has been replaced by the reviewed deterministic build.
The manifest, locked recipe and `CoreMLFaceEmbedder` declare RGB and Torch 2.8.0; a checked-in
color-asymmetric fixture proves RGB through Torch and Core ML, its swapped-BGR negative differs materially,
and two independent locked builds produce identical packages and canonical receipts whose artifact hashes
match the manifest. A compact checked-in reference also passes the app's actual `CGImage` preprocessing and
model-backed embed path with the BGR-negative separation. Published recognition still requires hardened
download/archive installation plus the production distribution trust key and signature.
