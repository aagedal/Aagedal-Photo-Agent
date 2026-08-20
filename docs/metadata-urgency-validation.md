# Editorial urgency validation

**Date:** 2026-08-21  
**Standard:** IPTC Photo Metadata Standard 2025.1  
**Field:** Urgency (`photoshop:Urgency`, IPTC-IIM 2:10)

## Implemented contract

- `IPTCMetadata.urgency` stores the canonical integer independently of localized UI text.
- Metadata editing, import configuration, and template editing offer values 1 through 8, where 1
  is most urgent and 8 is least urgent. Existing out-of-range integers remain visible until fixed.
- XMP sidecars and embedded raster writes use `photoshop:Urgency`; embedded compatible files also
  carry IPTC-IIM 2:10.
- Reads prefer XMP when XMP and IIM disagree and fall back to IIM when XMP is absent.
- An authoritative clear removes both XMP and IIM representations.
- The default validation profile blocks nonempty values outside 1 through 8. The IIM compatibility
  profile and generated boundary corpus record the dataset's one-byte limit.
- JSON sidecars, history, batch edits, imports, templates, field variables, browser search,
  rendered exports, and FTP/SFTP preparation use the same value.

## Automated evidence

Focused tests cover:

- JSON and merge round trips.
- XMP-sidecar and embedded-JPEG writes, XMP-over-IIM precedence, IIM fallback, and clear behavior.
- All eight accepted values plus lower and upper out-of-range validation failures.
- Template persistence and `{field:urgency}` interpolation.
- Rendered-export sidecar overlay.
- The generated IPTC-IIM boundary corpus entry for dataset 2:10.

External Bridge, Photo Mechanic, IPTC reference-tool, and non-JPEG container verification remain
part of the Phase 0 and Phase 1 interoperability gates.
