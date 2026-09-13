# Cycle 22 — verified voice-memo relationship reassociation

**State:** COMPLETE for user-scoped moved-relationship discovery, exact transactional
reassociation and automated verification. Overall 3.0 readiness remains **IMPLEMENTING** because
authentic Sony/native-volume evidence, transcription/delivery and broader release gates remain open.

## Source and scope

- Caption now offers **Find moved relationship…** for a photo without an adjacent relationship.
  The user selects a folder; recursive enumeration, record decoding and hashing remain inside that
  security scope on a retained utility executor.
- Relationship records retain an optional path/resource discovery hint. The hint is only a search
  and changed-source classifier: photo and WAV byte count plus SHA-256 remain authoritative.
- Discovery reports one exact candidate, duplicate/ambiguous exact candidates, a changed source or
  no match. Schema-1 filenames and a filename match alone never establish historical identity.

## Transaction boundary

A unique exact result copies the proven WAV beside the current photo, rewrites a new adjacent hidden
relationship and records `exactReassociation` provenance. The selected relationship and WAV remain
untouched. Unknown relationship fields and a transcript approval bound to the same exact audio hash
survive.

Preparation uses a private sibling directory. The service revalidates current photo bytes, selected
record bytes and selected WAV bytes before installation, reserves both destination names, installs
without replacement and verifies record read-back, memo identity and repository lookup. Failure rolls
back only operation-owned destinations and reports cleanup residuals. Navigation or disappearance
cancels request ownership, prevents a late result from publishing and prevents commit after discovery.

## Automated verification

- The affected repository and Caption suites pass 51 tests with zero failures. New cases cover exact
  renamed-photo reassociation, source preservation, opaque-field and hint retention, duplicate record/
  WAV ambiguity, changed versus missing results, destination collision, second-install rollback,
  utility-executor/security-scope ownership and navigation cancellation.
- The final serial no-build suite passes 2,866 tests in 312 suites with zero failures in 124.526
  seconds.
- `scripts/ci/validate_repository.sh` passes generated documentation, release metadata, 29 JSON
  documents, two property lists plus the Xcode project, bundled component/model provenance, logger/
  investigation privacy, conflict-marker and whitespace checks.

The existing synthetic LMDB map-full and media-decoder diagnostics remained visible. Independent
review and native picker interaction were not performed for this cycle.

## Remaining evidence and work

1. Exercise moved-relationship discovery and reassociation through the native picker with authorized
   Sony samples, including relaunch, duplicate exact folders, changed bytes, keyboard/VoiceOver,
   destination collision, disappearing sources and physical volumes. Never commit private media.
2. Exercise all RAW archive formats with real inputs, DNG Converter and C2PA, then prove playback and
   exact recovery/reassociation after the archive source is unavailable.
3. Implement reviewed local transcription with the reserved audio-hash binding, carrier-neutral
   transcript variables and visible Deadline WAV policy/receipts.
