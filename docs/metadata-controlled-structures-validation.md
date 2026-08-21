# Controlled editorial structures validation — 2026-08-21

## Implemented boundary

- Legacy Subject Codes retain ordered eight-digit values, accept URI/QCode/IIM aliases on read,
  and write `Iptc4xmpCore:SubjectCode` plus repeatable IIM Subject Reference values.
- Media Topics use repeatable `Iptc4xmpExt:AboutCvTerm` structures.
- Genre uses its separate repeatable `Iptc4xmpExt:Genre` CV-Term structure. It is never aliased to
  or written over legacy scalar Intellectual Genre.
- CV-Terms retain vocabulary identifier, term identifier, optional name, and optional refined-about
  identifier. Unknown valid terms remain visible and survive unrelated edits.
- Image Supplier uses an ordered `plus:ImageSupplier` sequence with PLUS identifier/name children.
  Image Supplier Image ID remains a separate scalar, writes canonical
  `plus:ImageSupplierImageID`, and reads the namespace emitted by older Photo Agent builds as a
  migration fallback.
- History, templates, import, batch operations, validation, and read-back use typed or lossless JSON
  transport rather than comma-delimited structured values.

SwiftExif 1.9.10 does not mark a newly created PLUS Image Supplier structured array as an RDF
sequence. The app seeds only that property with its standards-required sequence form before
applying values; exact XML coverage prevents a regression to an RDF Bag. This workaround can be
removed after the dependency recognizes `plus:ImageSupplier` as a sequence itself.

## Evidence

An isolated app/test-target build succeeded, followed by 51 tests in four suites with no failures:

- `EditorialImageSupplierTests`
- `EditorialMetadataInteroperabilityTests`
- `MetadataFieldMutationTests`
- `IPTCMetadataVerificationTests`

The focused evidence covers model/Codable normalization, unknown-value preservation, stable
field/write/verification registries, Subject IIM and XMP mappings, CV-Term XMP structures, canonical
PLUS scalar migration, ordered Supplier XML, structured mutation/history, parser precedence, and
semantic read-back. PBX lint, fixture/repository JSON parsing, conflict-marker scanning, and
`git diff --check` passed.

## Remaining evidence

Current Bridge, Photo Mechanic, and IPTC reference-tool round trips remain manual. Licensed
HEIC/HEIF and representative camera RAW originals are also still absent from the redistributable
fixture corpus.
