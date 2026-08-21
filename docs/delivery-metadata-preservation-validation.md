# Delivery metadata preservation validation

**Validated:** 2026-08-21  
**Scope:** Phase 5 source-to-staged unrelated-metadata verification

## Implemented contract

- Typed privacy-safe snapshots independently fingerprint unrelated EXIF, IPTC, XMP, and Camera Raw
  domains. Explicit format capabilities distinguish supported, unsupported, and unknown checks.
- Profile-controlled descriptive/GPS/rating/label fields and renderer-owned orientation,
  dimensions, thumbnails, and creator-tool facts are excluded from the unrelated identity. Camera
  Raw identity is checked for exact copies and explicitly unsupported for rendered deliveries.
- Delivery accepts only a semantic match or an explicitly unsupported carrier boundary. A proven
  mismatch and an unconfirmed/unknown read both fail closed.
- Staging stores the complete preservation report on each item and performs this check before
  assigning the SHA-256 that seals verified bytes for upload.
- C2PA carriage is a separate consequence (`absent`, `carried`, `removed`, `added`, or `changed`).
  Carried bytes are never described as valid provenance; signature validation remains outside this
  metadata comparison.

## Test evidence

An isolated app/test `build-for-testing` succeeded. A focused no-rebuild run of
`MetadataPreservationVerificationTests` and `StagedDeliveryCoordinatorTests` passed **17 tests in
2 suites**, zero failures. Coverage includes real embedded JPEG/XMP controlled writes, changed and
removed unrelated data, controlled-field exclusion, renderer-owned exclusion, exact-copy versus
rendered Camera Raw policy, explicit unsupported carriers, unreadable/unknown fail-closed behavior,
mandatory staging mismatch/unconfirmed failures, and preservation-stage cancellation. PBX parsing
and `git diff --check` passed.

## Known boundaries

- The live adapter compares embedded metadata; adjacent sidecars are not delivery artifacts.
- C2PA byte carriage is reported but cryptographic signature/trust validation is not performed.
- Structural EXIF pointers, GPS, embedded thumbnails, and renderer-owned output facts are excluded
  intentionally; the controlled-field verifier covers the profile-owned values.
