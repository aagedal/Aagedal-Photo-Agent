# Cycle 24 — durable voice-memo transcript review

**State:** COMPLETE for source-bound transcript persistence, explicit approval and edit-triggered
revocation. Overall 3.0 readiness remains **IMPLEMENTING** because transcript variables, Deadline
WAV policy, the broader injected failure matrix and native/offline/Sony evidence remain open.

## Source and scope

- The implementation continues cycle 23 checkpoint `19bad87` on `main`.
- Caption loads a persisted transcript only after rechecking the current relationship plus the exact
  WAV SHA-256 and byte count. Approval rechecks the same evidence before and after the serialized
  write; a stale or replaced memo cannot become usable reviewed text.
- Generated text, human-reviewed text, provider/model disclosure, locale, generation time, source
  filename hints, association profile, WAV identity and approval time persist separately. Approval
  does not change Description, Extended Description or any other IPTC field.
- Editing approved text revokes approval and persists the revoked state before further review. A
  failed or cancelled replacement transcription leaves the earlier approved record intact.

## Storage boundary

`voiceMemoTranscript` is a versioned top-level extension in the existing
`.photo_metadata/<full-image-filename>.meta.json` carrier. It deliberately remains outside
`MetadataSidecar`'s whole-record coding keys. `MetadataSidecarService` reads and patches the
extension on `MetadataSidecarFilesystemActor` under the existing per-photo `MetadataIOCoordinator`
lock, with atomic install and read-back verification.

Same-schema unknown nested transcript fields survive a review update. A newer nested transcript
schema is rejected without changing a carrier byte. Ordinary sidecar saves retain the extension;
post-image-write and refresh cleanup now retain meaningful opaque top-level extensions rather than
deleting the complete carrier. Existing raw copy and relocation paths carry the opaque transcript
graph while updating only the carrier's `sourceFile` owner.

## Automated verification

- Thirteen focused tests in `CaptionVoiceMemoTranscriptionTests` and
  `VoiceMemoTranscriptSidecarTests` pass. They cover exact provenance round-trip, generated versus
  reviewed text, approval/revocation, failed replacement retention, unknown nested/top-level field
  preservation, newer nested schema refusal, ordinary metadata save/finalization/refresh cleanup,
  copy, relocation and cancellation of a replacement while an approval exists.
- The broader sidecar/coordinator run passes 61 tests in four suites. The final serial suite passes
  2,879 tests in 314 suites with zero failures in 114.297 seconds.
- `scripts/ci/validate_repository.sh` passes generated documentation, release metadata,
  JSON/property-list/project parsing, bundled component/model provenance, logger/investigation
  privacy, conflict-marker and whitespace checks.
- Existing compiler warnings and synthetic LMDB map-full diagnostics remain visible; no new warning
  is attributed to this slice. Independent source review and native UI/recognition were not run.

## Remaining work

1. Resolve only approved exact-audio-bound text through `{voiceMemoTranscript}` and add explicit
   Append/Replace preview and application through the existing metadata history/write boundary.
2. Add visible Deadline WAV include/exclude policy and record the disposition in delivery receipts.
3. Complete unsupported/offline, cancelled installation, empty/malformed audio, result-consumer,
   finalization, long-file cancellation and reservation-limit tests.
4. Run native download/failure/retry, installed-offline recognition, permission, navigation,
   relaunch and authorized Sony WAV checks without committing private audio.
5. Broaden lifecycle evidence through real archive/recovery/reassociation and physical-volume cases.
