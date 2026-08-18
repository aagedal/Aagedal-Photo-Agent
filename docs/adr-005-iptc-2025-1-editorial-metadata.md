# ADR-005: IPTC 2025.1 editorial metadata baseline

- **Status:** Accepted
- **Date:** 2026-08-18
- **Owners:** Aagedal Photo Agent

## Context

Photo Agent is intended to replace Adobe Bridge and Photo Mechanic for metadata work in a
journalistic workflow. That claim needs a fixed, testable interoperability target. The app already
reads and writes a useful subset of IPTC, but its supported vocabulary, container behavior, and
compatibility promises were not documented in one place.

The current implementation also stored and wrote short Digital Source Type identifiers such as
`digitalCapture`. IPTC defines this property as a URI whose value comes from the Digital Source
Type NewsCodes vocabulary. Existing templates and sidecars may still contain the short form.

## Decision

### Standards baseline

The product targets **IPTC Photo Metadata Standard 2025.1**, the latest final specification at the
time of this decision.

Normative implementation references:

- [IPTC Photo Metadata Standard 2025.1](https://iptc.org/std/photometadata/specification/IPTC-PhotoMetadata)
- [IPTC 2025.1 machine-readable technical reference](https://iptc.org/std/photometadata/specification/iptc-pmd-techreference_2025.1.json)
- [Digital Source Type NewsCodes](https://cv.iptc.org/newscodes/digitalsourcetype/)

A future standard release requires a new decision or an amendment to this ADR, an updated support
matrix, and passing interoperability fixtures before the product claims the newer version.

### Representation policy

- XMP is the authoritative modern representation for fields that do not exist in IPTC-IIM.
- Where the standard defines both XMP and IPTC-IIM mappings, Photo Agent writes both when the file
  container and metadata engine support them.
- RAW and protected formats use XMP sidecars. Embedded writes must preserve unrelated metadata.
- Unknown namespaces, unknown properties in known namespaces, and supported structured values are
  preserved during no-op and unrelated-field edits.
- Typed, versioned `Codable` models are used for repeatable or structured values. Flattening a
  structured value into a display string is not an acceptable persistence format.
- When embedded XMP and IPTC-IIM disagree, the current reader preference is documented in the
  support matrix and must eventually be surfaced as a validation warning instead of silently
  destroying one value.

### Digital Source Type compatibility

Photo Agent stores the stable short identifier internally and in existing template/history JSON,
but its metadata boundary behaves as follows:

- Write the canonical URI
  `http://cv.iptc.org/newscodes/digitalsourcetype/{identifier}`.
- Read canonical HTTP URIs, equivalent HTTPS URIs, `digsrctype:` QCodes, and legacy short tokens.
- Offer all active 2025.1 vocabulary concepts in the picker.
- Do not offer retired concepts in new metadata. Unknown values remain preservation concerns; they
  must not be silently reclassified as a known value.

This keeps existing user data working while producing standards-conformant metadata for other
applications.

### First editorial field set

The first compatibility milestone covers the fields marked Supported, Partial, or Planned in
`iptc-2025.1-editorial-support.md`. Work is prioritized around captioning, creator/contact,
locations, rights, newsroom routing, controlled vocabularies, and identifiers. Specialist artwork,
product, model-release, licensing, registry, and accessibility fields remain preservation targets
until they receive deliberate UI and validation designs.

## Conformance evidence

The support matrix is a living engineering artifact, not a marketing checklist. A field becomes
**Supported** only when it has:

1. Model and persistence coverage.
2. Read and write mapping tests.
3. UI or an explicitly documented headless-only use.
4. A real-file round-trip fixture with preservation assertions.
5. Bridge and Photo Mechanic interoperability notes where either tool exposes the field.

The release process will generate a user-facing support statement from this evidence and run the
IPTC interoperability test suite when the fixtures are added.

## Consequences

- Existing short Digital Source Type values continue to load, while new file writes change to the
  canonical URI.
- Some currently combined concepts, especially Headline and Title, must be separated before the
  app can claim full support.
- Adding fields alone is insufficient: preservation, conflict handling, container behavior, and
  external round trips are part of the definition of support.
- This ADR deliberately does not claim full IPTC 2025.1 coverage.

