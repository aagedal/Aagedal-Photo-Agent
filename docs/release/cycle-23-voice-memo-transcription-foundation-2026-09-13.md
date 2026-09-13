# Cycle 23 — local voice-memo transcription foundation

**State:** COMPLETE for the explicit Apple on-device recognition and editable in-memory draft slice.
Overall 3.0 readiness remains **IMPLEMENTING** because reviewed transcript persistence/approval,
metadata variables, delivery policy, native recognition evidence and broader release gates remain open.

## Source and scope

- The implementation is based on cycle-22 checkpoint `8c93a5c` on `main`.
- Caption exposes transcription only for an available persisted WAV relationship. Playback remains
  independent, and neither loading nor playing audio triggers recognition or asset installation.
- Runtime Speech availability and supported locales populate an explicit language picker. Installed,
  download-required, downloading and unavailable states stay visible. **Download Language** is a
  separate user action; there is no network-capable recognizer fallback or microphone capture.
- The result is an editable in-memory draft with distinct generated and reviewed text plus provider,
  system-managed model disclosure, locale, generation time, association profile and exact WAV identity.
  No draft, edit, failure or cancellation writes metadata or changes the relationship record.

## Recognition and ownership boundary

`VoiceMemoTranscriptionService` is isolated to a retained utility `DispatchSerialQueue`. It opens the
associated WAV through the existing folder security scope, feeds `AVAudioFile` into `SpeechAnalyzer`,
consumes final `SpeechTranscriber` results concurrently and finalizes the analyzer before publishing.
Cancellation owns the result consumer and analyzer teardown.

The service captures a streaming SHA-256/byte-count revision before recognition, captures it again
after recognition and rechecks the repository relationship. Changed audio or relationship evidence
discards the generated text. `CaptionVoiceMemoTranscriptModel` gives each request generation ownership;
navigation, refresh and disappearance cancel work and reject a late result before it can reach the UI.
Cancelling an active replacement leaves an existing draft intact, while changing photos clears it.

## Automated verification

- Six focused transcription tests pass. They cover installed/download-required availability, explicit
  install plus status recheck, utility-executor ownership, exact source/provenance binding, changed-WAV
  rejection, stale-navigation cancellation and the no-metadata-write presentation contract.
- The adjacent Caption playback suite passes 13 tests, including navigation cancellation, source
  changes, security-scope teardown, recovery and moved-relationship ownership.
- The final serial no-build suite passes 2,872 tests in 313 suites with zero failures in 133.317 seconds
  (Xcode elapsed 145.321 seconds).
- `scripts/ci/validate_repository.sh` passes generated documentation, release metadata, JSON/property-
  list/project parsing, bundled component/model provenance, logger/investigation privacy, conflict-marker
  and whitespace checks.

Existing synthetic LMDB map-full and media diagnostics remained visible. Independent source review and
native UI/recognition were not performed for this cycle.

## Remaining evidence and work

1. Persist the versioned source-bound transcript extension through `MetadataSidecarService`'s existing
   serialized transaction. Preserve newer/unknown fields and prove ordinary saves, history, move,
   reject, archive, recovery and reassociation cannot erase or misbind it.
2. Add explicit review approval and edit-triggered revocation. A failed or cancelled replacement must
   retain a prior approved record; no approval action should mutate an IPTC field by itself.
3. Complete injected unsupported/offline, cancelled installation, empty/malformed audio, result-consumer,
   finalization and long-file cancellation coverage, including reservation-limit behavior.
4. Exercise explicit download/failure/retry and installed recognition natively with networking disabled,
   no unexpected permission prompt, navigation cancellation and authorized Sony WAVs. Never commit
   private audio.
5. Resolve only exact approved audio-bound text through `{voiceMemoTranscript}`, add explicit Append/
   Replace metadata preview, and make Deadline WAV inclusion/exclusion visible in preflight and receipts.
