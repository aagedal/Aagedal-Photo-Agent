# Cycle 86 — bundled Whisper and in-app model downloads

Baseline: `ca9602b`. Implements the requested embedded FFmpeg and downloadable Whisper models while keeping all setup in Settings → Transcription.

## Implementation

- Replaces the photo-only helper with the patched Media Converter-derived FFmpeg 9.0.1 build. Nine image conversions retain exact decoded pixels. Canonical JSON escaping and bounded timestamps remain patched.
- Adds managed Whisper alongside Apple Speech and the advanced custom provider. Tiny, Base and Small multilingual models have immutable download URLs, exact sizes and SHA-256 pins. Downloads are explicit, streamed, cancellable and installed atomically only after validation. Removal and offline reuse are supported.
- Generates a runtime descriptor after nested helper signing, then seals it with the app signature. Managed admission checks that seal and exact runtime/model identities. Every inference revalidates the admitted artifacts.
- Keeps Caption limited to provider status, Settings navigation and Transcribe. Language/translation/GPU options and model management live in Settings. Transcript review/approval and metadata writes are unchanged.
- Extends read-only MCP discovery to all three providers without claiming knowledge of app readiness. Updates privacy, licenses, help, limitations and provenance.
- Independent review found and fixed receipt revocation during a routine Settings refresh: a ready receipt now survives reopening Settings, while inference still checks the exact files.

## Validation

The real production download service fetched Tiny (77,691,713 bytes) from the pinned Hugging Face revision and passed checksum verification and installed-file revalidation. That downloaded model produced canonical timestamped JSON from the bundled FFmpeg for the local JFK sample with CPU inference and a local-only protocol whitelist. This checks integration, not transcription accuracy.

Artifact validation passed nine decoded-image comparisons, six CPU runtime/error/cancellation scenarios, eight bundled-component validator tests, and the sanitizer harness (63 round trips, 14 fault cases, 11 timing cases and 12 allocation points). Repository validation passed.

Full integrated regression passed **3,230 tests / 338 suites** in 127.497 seconds, with zero failures. This includes signed-app runtime admission, unsigned-bundle refusal, six managed setup lifecycle tests and verified download failure/cancellation coverage. The live rebuilt MCP helper probe passed all 15-tool protocol/discovery checks.

Three native workflows passed in 101.506 seconds: managed Whisper Settings with no implicit download and clean Caption; custom file/consent setup; and persisted custom options. Fixtures remained unchanged. The final copy-only adjustment labels cached-model admission retry as “Retry Setup”.

## Remaining before release

The bundled binary is a development integration. Publish the complete corresponding source companion (including dependencies and local patches) and prove a clean rebuild before distribution. Complete signed model update/rollback/recovery policy, broader offline/GPU/accuracy acceptance, privacy/legal review and signed/notarized candidate acceptance. Production MCP executors and guarded IPTC commits remain required v3.0 work, along with the broader native/accessibility, authentic voice-memo, external-server and cloud evidence tracked in readiness.md. This cycle does not close those broader gates.
