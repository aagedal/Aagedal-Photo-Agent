# Editorial metadata fixtures

These fixtures exercise preservation and interoperability behavior for the IPTC 2025.1 editorial
workstream. Every file in this directory is generated for Aagedal Photo Agent and may be
redistributed under CC0-1.0. It contains no personal data, copyrighted photography, or third-party
production metadata.

## Fixture inventory

### `preservation-complex.xmp`

A synthetic XMP packet containing:

- Supported editorial fields and a canonical Digital Source Type NewsCodes URI.
- Two ordered creators and multiple people shown.
- Planned IPTC fields in known namespaces, including Caption Writer, Urgency, Country Code, Scene,
  Usage Terms, and two structured Location Shown entries.
- A foreign newsroom namespace with both a scalar and an array.
- Unicode, punctuation, commas, a semicolon, and a multiline caption.
- An unmodeled Camera Raw property.

Tests compare every parsed XMP property before and after a reader/writer round trip, then change
only the caption and verify that the multi-creator sequence, structured locations, controlled
terms, and foreign properties survive.

## Generated-at-test-time fixtures

Tests generate a minimal JPEG in memory for the no-metadata and embedded-XMP cases. This avoids
checking opaque binary files into the repository while still exercising the real SwiftExif
container writer. The conflicting XMP/IIM description case is built as a deterministic metadata
dictionary because the precedence rule belongs to the app adapter, not to a particular container.

## Corpus still needed

Before Phase 0 can close, add legally redistributable real-file samples for TIFF, PNG, HEIC/HEIF,
JPEG XL, and representative RAW+XMP pairs, plus external round-trip outputs from Adobe Bridge and
Photo Mechanic. Those files must document provenance and redistribution permission here.

