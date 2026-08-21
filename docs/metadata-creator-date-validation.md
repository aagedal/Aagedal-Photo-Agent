# Ordered Creator and typed Date Created validation — 2026-08-21

## Implemented boundary

- `IPTCMetadata.creators` is the ordered source of truth. The shipped scalar `creator` API and JSON
  key remain a writable first-item compatibility alias; current JSON also carries the complete
  sequence.
- `dc:creator` is written as an ordered RDF sequence and IIM 2:80 as repeatable ordered By-line
  datasets. History, templates, import, batch append/replace/clear/reorder, autocomplete,
  interpolation, validation, and read-back preserve sequence order.
- `EditorialDateCreated` validates ISO 8601 partial dates and timestamps while retaining exact
  lexical spelling, canonical spelling, represented precision, fractional digits, and explicit
  absent/unknown/known-offset timezone semantics. RFC 3339 `-00:00` remains unknown.
- The shipped `dateCreated` string JSON/API contract remains compatible through the typed
  projection. New editor input is validated; invalid legacy text remains preservable rather than
  being silently normalized.
- `photoshop:DateCreated` is authoritative. IIM 2:55/2:60 receives only components it can represent
  losslessly; exact XMP is retained for partial, fractional, or timezone-unknown values.

## Evidence

The strict-concurrency app target compiled successfully. Focused current-source runs passed 211
logical tests across 19 suites with no failures. Coverage includes:

- 11 accepted and 16 rejected Date Created lexical parameter cases plus Codable and Sendable checks.
- Legacy scalar Creator migration and older-reader first-item compatibility.
- Ordered sidecar and embedded-JPEG XMP Creator sequences and repeatable IIM By-lines.
- Exact XMP Date Created read-back plus representable IIM date/time projections.
- History, mutation, template, import, batch selection, variable interpolation, autocomplete,
  validation, remediation routing, and semantic verification.

PBX lint and `git diff --check` passed. The console emitted only the separately tracked validation-
host startup diagnostics; no Creator/Date compiler or test diagnostic occurred.

## Compatibility boundary

Older Photo Agent builds can read only the first Creator through the retained scalar key. IIM
cannot carry every ISO 8601 precision/timezone distinction, so XMP/JSON remain canonical. Localized
`dc:title` is a separate unresolved carrier-model task and is not claimed by this record.
