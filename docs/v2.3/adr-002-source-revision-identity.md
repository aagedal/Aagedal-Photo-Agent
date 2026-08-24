# ADR-002 — Exact source revision identity and reassociation

**Status:** accepted for 3.0
**Decision date:** 2026-07-26
**Recorded:** 2026-08-24

## Decision

Persisted analysis, comparison, and named-version state binds to an exact `SourceImageRevision`.
The authoritative identity is the source byte count plus its lowercase SHA-256 digest. Canonical
path, filename, filesystem resource identifier, modification date, dimensions, and EXIF
orientation are retained as discovery, cache, compatibility, or presentation facts; none can
replace the content-hash check.

Revision capture streams the file through SHA-256, supports cancellation, and compares file facts
before and after hashing. A source that changes during capture is rejected rather than producing a
mixed or stale identity.

Discovery checks the recorded path and resource identifier first, then filename and other
same-sized candidates, but it hashes every candidate before declaring an exact match. The result
distinguishes:

- the exact revision at its current path;
- the exact revision found by filesystem identifier or content hash;
- multiple exact copies that require an explicit user choice;
- the same path or filesystem object with changed bytes; and
- no located source.

An exact-byte rename or move may refresh only path and filesystem discovery hints. Changed bytes
remain a different revision: existing findings, annotations, comparison state, or named versions
must not be silently applied. Named-version reassociation to changed bytes is an explicit copy,
preserves the old catalog, and requires compatible source geometry or a deliberate geometry choice.

## Rationale

Paths and filesystem identifiers are useful locally but are neither portable nor proof that the
bytes are unchanged. A streamed cryptographic digest gives every evidence and editing feature one
portable revision boundary while still allowing fast candidate ordering and deliberate recovery
after moves.

## Consequences

- A file replaced in place is surfaced as source changed even when its path is unchanged.
- A unique byte-for-byte moved copy can be reassociated; ambiguous copies require user selection.
- Resource identifiers are stored opaquely and cleared when a portable relocation cannot preserve
  their meaning.
- Hashing large files remains cancellable and must not read the full source into one `Data` value.
- Reports and other immutable evidence revalidate the exact source revision at their durable
  boundary.

## Implementation evidence

- [Source identity architecture](storage-and-architecture.md#source-identity)
- [Analysis shell validation](phase-2-analysis-shell-validation.md)
- [Comparison core validation](phase-7-comparison-core-validation.md)
- `SourceImageRevision`, `SourceImageDiscoveryService`, `AnalysisCaseRepository`, and
  `DevelopVersionCatalogRepository`
