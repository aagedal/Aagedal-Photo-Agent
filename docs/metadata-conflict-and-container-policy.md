# Metadata conflict and container policy

This document records current behavior for the IPTC 2025.1 interoperability work. It is an
engineering contract and must stay aligned with fixtures and tests.

## XMP and IPTC-IIM conflicts

Photo Agent reads both stores before building the editable metadata record. Current precedence is:

| Field | Current displayed value | Conflict surfaced? |
| --- | --- | --- |
| Description / Caption | XMP `dc:description` | Yes; the editor lets the user choose XMP or IIM. |
| Headline | IPTC-IIM 2:105, then XMP `photoshop:Headline` | No, planned. |
| Title | Headline alias first, then XMP `dc:title`, then IIM Object Name | No, field split planned. |
| City | IPTC-IIM, then XMP | No, planned. |
| Credit | IPTC-IIM, then XMP | No, planned. |
| Province/State | XMP, then IPTC-IIM | No, planned. |
| Country | XMP, then IPTC-IIM | No, planned. |
| Source | XMP when both exist | No, planned. |

The inconsistent precedence is retained temporarily to avoid silently changing existing newsroom
behavior. Phase 1 will replace these field-specific fallbacks with a shared conflict resolver. The
intended end state is: retain both source values, display a warning, use XMP as the proposed modern
value, and require an explicit resolution before a destructive synchronization. Once a user edits
or resolves a field, supported fields are synchronized to XMP and IPTC-IIM where both mappings
exist.

## Write boundaries by file category

| Category | Default professional behavior | Safety boundary |
| --- | --- | --- |
| JPEG | Embedded metadata | SwiftExif read-modify-write; preservation fixtures required. |
| TIFF | Embedded metadata | Normal camera TIFFs supported; rendered-TIFF override is restricted to export output. |
| PNG | Embedded metadata | Container support exists; real-file editorial fixture still required. |
| HEIC/HEIF | Embedded metadata | Container support exists; real-file write/preservation fixture still required. |
| JPEG XL | Embedded metadata | Container support exists; real-file write/preservation fixture still required. |
| AVIF/WebP | Embedded metadata | Engine support exists, but these are not yet part of the first public editorial guarantee. |
| Camera RAW, including DNG | XMP sidecar | Embedded writes are refused in every preset to protect maker-private data. |
| C2PA-protected image | XMP sidecar | Professional/custom modes avoid invalidating the credential. Simple mode is an explicit opt-in to embedded mutation. |
| BMP/GIF | Treat as viewable, not editorial-write guaranteed | Do not claim IPTC interoperability until container tests prove it. |

“Supported by the engine” is not the same as “guaranteed by the product.” A format enters the
public guarantee only after its real-file fixture passes read, write, unrelated-edit preservation,
and external-tool checks.

### SwiftExif follow-up tasks

- Preserve all language entries in XMP `rdf:Alt`; the current value model exposes only
  `x-default`, so localized alternatives cannot yet receive a preservation guarantee.
- Add fixture-backed capability tests for TIFF, PNG, HEIC/HEIF, JPEG XL, AVIF, and WebP instead of
  inferring product support from parser/writer cases alone.
- Expose enough source-store information to build a generic XMP/IIM conflict report rather than
  reconstructing conflicts from a flattened dictionary.
- Verify ordered vs unordered array form for every selected repeatable IPTC property against the
  2025.1 TechReference and external tools.

## Sidecar preservation rule

An XMP sidecar update starts from the parsed existing packet and mutates only fields owned by the
operation. Unknown namespaces, unmodeled properties in known namespaces, structured values, and
repeatable values must remain semantically identical. Formatting and prefix choice may normalize;
property identity, type, order where meaningful, and values may not.

Because the current model exposes only the primary creator, an unchanged first creator is treated
as evidence that an existing multi-creator sequence was not edited and the complete sequence is
preserved. A changed creator deliberately replaces that sequence until Phase 1 introduces an
ordered creator model.

## Legacy IPTC-IIM editing policy

The following fields remain editable and dual-written where an IIM mapping exists because they are
still common in wire-service handoffs: Headline, Title/Object Name, Description, Keywords, Creator,
Creator Job Title, Credit Line, Copyright Notice, Instructions, Job ID, Date Created, City,
Sublocation, Province/State, Country Name, Country Code, Source, and Urgency.

Legacy Subject Codes are read and preserved, but the new classification UI will prefer IPTC Media
Topics/CV Terms. Intellectual Genre remains preservation-only until it has a controlled-vocabulary
editor. IIM byte limits are compatibility warnings, not limits on the richer XMP value; Deadline
Mode may promote them to blocking errors when a newsroom profile explicitly requires IIM delivery.

## Editorial date representation

Phase 1 will replace `IPTCMetadata.dateCreated`'s display string with a lossless value containing:

- Calendar components and explicit precision: year, month, day, minute, second, or fractional
  second as actually supplied.
- Timezone state separated into known UTC offset, explicitly unknown/local time, or absent.
- The original lexical value when it cannot be safely normalized.

XMP writes use an ISO 8601/W3C-DTF value without inventing missing components or a timezone. IIM
writes split the value into Date Created (2:55) and Time Created (2:60) only for components that are
known. A date-only source does not gain midnight, and a time without a known offset does not gain
the computer's current timezone. Existing string values migrate by parsing recognized forms; an
unrecognized value remains opaque and editable instead of being discarded.
