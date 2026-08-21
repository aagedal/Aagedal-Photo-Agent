# Batch Rename original-filename metadata validation — 2026-08-21

Batch Rename recipes now have an explicit, backward-compatible original-filename policy. Existing
recipes decode to `doNotWrite`; an opted-in recipe freezes an XMP Media Management
`xmpMM:PreservedFileName` mutation into the immutable artifact action. The implementation does not
reuse IPTC IIM 2:103 / `photoshop:TransmissionReference`, whose IPTC meaning is the receiver's
workflow Job ID.

JPEG writes target embedded XMP. Proprietary RAW writes target an existing adjacent XMP sidecar and
block during planning if no sidecar exists rather than creating an ambiguous new carrier. The
production codec prepares pure replacement bytes through SwiftExif while preserving unrelated XMP.
Execution stages every source, writes the frozen metadata bytes, and only then commits destination
names. Cancellation or a later failure restores exact original bytes before restoring source paths.

The established `xmpMM:PreservedFileName` property is documented by ExifTool and consumed by Adobe
Bridge. Adobe's current public XMP Media Management page documents the namespace but does not list
this property in its displayed table, so this is recorded as the established Adobe/ExifTool mapping,
not as an IPTC field or a newly invented private namespace. Manual Bridge/Photo Mechanic inspection
remains required for release evidence.

An isolated build-for-testing succeeded. Fifty-seven tests across six rename suites passed, and the
latest transaction-order subset passed four of four. Coverage includes legacy migration, repository
round trips, exact namespace/property use, absence of TransmissionReference mutation, unrelated-XMP
preservation, JPEG, RAW+XMP cycles, move/write/commit ordering, cancellation, later write failure,
and byte-exact rollback. `git diff --check` and conflict scanning passed.
